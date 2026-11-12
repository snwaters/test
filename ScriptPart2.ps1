<#
.SYNOPSIS
    ScriptPart2.ps1 - Post-reboot provisioning and endpoint configuration.
.DESCRIPTION
    Native PowerShell conversion of ScriptPart2.bat for OSDCloud / SetupComplete.
    Optimized for Windows 10/11: direct cmdlet execution, fixed unclosed quotes,
    safe registry paths, and structured step execution.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " [OSDCloud] Running ScriptPart2.ps1 (Post-Reboot Setup)   " -ForegroundColor Cyan
Write-Host " Timestamp: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')    " -ForegroundColor Gray
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Delete cached OS remnants
Write-Host "[1/13] Executing Delete_cached_os.ps1..." -ForegroundColor Yellow
$scriptDeleteCache = "C:\osdcloud\Scripts\SetupComplete\Delete_cached_os.ps1"
if (Test-Path -Path $scriptDeleteCache) {
    & $scriptDeleteCache
} else {
    Write-Warning "Script not found: $scriptDeleteCache"
}

# 2. Delete unattended setup script from shutdown folder
Write-Host "[2/13] Cleaning up temporary unattended script..." -ForegroundColor Yellow
Remove-Item -Path "C:\osdcloud\Scripts\Shutdown\create_unattended.ps1" -Force -ErrorAction SilentlyContinue

# 3. Download and run sleep disable script (Fixed unclosed quote from batch)
Write-Host "[3/13] Downloading & running disable_sleep.ps1..." -ForegroundColor Yellow
$disableSleepPath = "C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1"
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
    $destFolder = Split-Path -Parent $disableSleepPath
    if (-not (Test-Path -Path $destFolder)) { New-Item -ItemType Directory -Path $destFolder -Force | Out-Null }
    
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/snwaters/test/refs/heads/main/disable_sleep.ps1" `
                      -OutFile $disableSleepPath `
                      -UseBasicParsing `
                      -ErrorAction Stop
                      
    if (Test-Path -Path $disableSleepPath) {
        & $disableSleepPath
    }
} catch {
    Write-Warning "Failed downloading or executing disable_sleep.ps1: $_"
}

# 4. Disable system sleep and display timeouts
Write-Host "[4/13] Setting powercfg timeouts to 0 (Never sleep/display off)..." -ForegroundColor Yellow
powercfg.exe /change standby-timeout-ac 0
powercfg.exe /change standby-timeout-dc 0
powercfg.exe /change monitor-timeout-ac 0
powercfg.exe /change monitor-timeout-dc 0

# 5. Export reboot events to log file
Write-Host "[5/13] Logging recent system reboot events..." -ForegroundColor Yellow
try {
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 1074 } -MaxEvents 10 -ErrorAction SilentlyContinue |
        Select-Object TimeCreated, Message |
        Format-Table -Wrap |
        Out-File -FilePath "C:\osdcloud\reboots.txt" -Append -Encoding utf8
} catch {
    Write-Warning "Could not query WinEvent 1074: $_"
}

<# Preserved commented-out operations from batch:
# Start-Sleep -Seconds 60
# Invoke-WebRequest -Uri "https://raw.githubusercontent.com/snwaters/test/refs/heads/main/install.ps1" -OutFile "C:\osdcloud\Scripts\SetupComplete\install.ps1" -UseBasicParsing
# & "C:\osdcloud\Scripts\SetupComplete\install.ps1"
# Add-LocalGroupMember -Group "Administrators" -Member "Turner-nt\Desktop_admins" -ErrorAction SilentlyContinue
#>

# 6. Enable Hyper-V Feature
Write-Host "[6/13] Enabling Microsoft-Hyper-V feature..." -ForegroundColor Yellow
try {
    Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Hyper-V" -All -NoRestart -ErrorAction Stop
} catch {
    Write-Warning "Native cmdlet failed, invoking Dism.exe directly..."
    & dism.exe /online /Enable-Feature /FeatureName:Microsoft-Hyper-V /All /NoRestart
}

# 7. Enable BIOS Virtualization Setting
Write-Host "[7/13] Running BIOS virtualization configuration script..." -ForegroundColor Yellow
$biosScript = "C:\osdcloud\Scripts\SetupComplete\Enable_virtual_setting in bios.ps1"
if (Test-Path -Path $biosScript) {
    & $biosScript
} else {
    Write-Warning "BIOS script not found: $biosScript"
}

# 8. Configure Virtualization-Based Security (VBS), Credential Guard, LSA, and PIN Logon
Write-Host "[8/13] Applying Security & Virtualization Registry policies..." -ForegroundColor Yellow
$regItems = @(
    @{ Path = "HKLM:\System\CurrentControlSet\Control\DeviceGuard"; Name = "EnableVirtualizationBasedSecurity"; Value = 1 }
    @{ Path = "HKLM:\System\CurrentControlSet\Control\DeviceGuard"; Name = "RequirePlatformSecurityFeatures"; Value = 3 }
    @{ Path = "HKLM:\System\CurrentControlSet\Control\LSA";         Name = "LsaCfgFlags";                     Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "AllowDomainPINLogon";              Value = 1 }
)

foreach ($item in $regItems) {
    if (-not (Test-Path -Path $item.Path)) {
        New-Item -Path $item.Path -Force | Out-Null
    }
    Set-ItemProperty -Path $item.Path -Name $item.Name -Value $item.Value -Type DWord -Force
}

# 9. Launch BGInfo Installation Batch
Write-Host "[9/13] Installing BGInfo..." -ForegroundColor Yellow
$bgInfoScript = "C:\osdcloud\Scripts\SetupComplete\BGInfo_11_2021\install.bat"
if (Test-Path -Path $bgInfoScript) {
    Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$bgInfoScript`"" -Wait -NoNewWindow
} else {
    Write-Warning "BGInfo installer not found: $bgInfoScript"
}

# 10. Install Winget Packages (System/Machine Scope)
Write-Host "[10/13] Installing software packages via winget..." -ForegroundColor Yellow
$wingetPackages = @(
    "Google.Chrome"
    "Google.GoogleDrive"
    "Lenovo.SystemUpdate"
    "Lenovo.DockManager"
)

foreach ($pkgId in $wingetPackages) {
    Write-Host " -> Installing $pkgId..." -ForegroundColor Cyan
    & winget install -e --id $pkgId --silent --accept-package-agreements --accept-source-agreements --source winget --scope machine --disable-interactivity
}

# 11. Run Windows Activation Script
Write-Host "[11/13] Running Windows Activation script..." -ForegroundColor Yellow
$activationScript = "C:\osdcloud\Scripts\SetupComplete\activation.ps1"
if (Test-Path -Path $activationScript) {
    & $activationScript
} else {
    Write-Warning "Activation script not found: $activationScript"
}

# 12. Register RunOnce to execute ScriptPart3 after the upcoming reboot
Write-Host "[12/13] Setting RunOnce entry for ScriptPart3..." -ForegroundColor Yellow
$runOnceKey = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce"
# Note: Use .ps1 if converting Part 3 as well, or keep .bat as in original:
$part3Cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\ScriptPart3.ps1"'
# Alternatively, if ScriptPart3 is still .bat:
# $part3Cmd = 'C:\osdcloud\Scripts\SetupComplete\ScriptPart3.bat'
Set-ItemProperty -Path $runOnceKey -Name "MyScriptPart3" -Value $part3Cmd -Type String -Force

# 13. Run Windows Update Script
Write-Host "[13/13] Executing Windows Update script..." -ForegroundColor Yellow
$updateScript = "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"
if (Test-Path -Path $updateScript) {
    & $updateScript
} else {
    Write-Warning "Windows update script not found: $updateScript"
}

# Preserved SentinelOne comment:
# Start-Process -FilePath "cmd.exe" -ArgumentList '/c "C:\osdcloud\Scripts\SetupComplete\SentinalOne\install.bat"' -Wait -NoNewWindow

# Final Reboot to trigger RunOnce ScriptPart3
Write-Host "Continuing to part 3 after reboot. Restarting in 5 seconds..." -ForegroundColor Magenta
Start-Sleep -Seconds 2
Restart-Computer -Force
