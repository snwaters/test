<#
.SYNOPSIS
    OSDCloud SetupComplete Post-Deployment Script (Fault-Tolerant)
.DESCRIPTION
    Converts SetupComplete.bat into native PowerShell with "Continue on Error" resilience.
    If any single download, MSI, or agent installer fails, it logs a clear warning
    and immediately continues execution so the remaining tasks and final reboot still run.
.PARAMETER JoinDomain
    Optional switch to force domain join without interactive prompt (useful for unattended OSD).
.PARAMETER SkipDomainJoin
    Optional switch to join JumpCloud-only without domain join.
.PARAMETER SkipReboot
    Do not restart the computer upon script completion (useful for testing).
#>
[CmdletBinding()]
param(
    [switch]$JoinDomain,
    [switch]$SkipDomainJoin,
    [switch]$SkipReboot
)

# -------------------------------------------------------------------------
# Environment & Continue-On-Error Configuration
# -------------------------------------------------------------------------
# Continue on non-terminating errors (mirrors batch behavior)
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue' # 10x faster downloads by disabling GUI progress bar

# Force modern TLS protocols (essential on fresh Windows 10/11 & WinPE images)
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
} catch {
    Write-Warning "Unable to set TLS 1.3, defaulting to available security protocols."
}

# Standard Target Directories
$ScriptDir = 'C:\osdcloud\Scripts\SetupComplete'
$TempDir   = 'C:\Windows\Temp'

# Ensure base working directories exist
if (-not (Test-Path -LiteralPath $ScriptDir)) {
    New-Item -Path $ScriptDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
}

function Write-Step {
    param([string]$Message)
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$timestamp] $Message" -ForegroundColor Cyan
}

# Resilient Step Execution Wrapper: Catches any terminating error and continues
function Invoke-SafeStep {
    param(
        [Parameter(Mandatory = $true)][string]$StepName,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock
    )
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$timestamp] >>> Starting: $StepName" -ForegroundColor Cyan
    try {
        & $ScriptBlock
        Write-Host "[$timestamp] [OK] Completed: $StepName" -ForegroundColor Green
    } catch {
        Write-Warning "[$timestamp] [WARNING] Non-fatal error during [$StepName]: $_"
        Write-Host "[$timestamp] Continuing to next deployment task..." -ForegroundColor Yellow
    }
}

function Invoke-ScriptDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $parent = Split-Path -Path $OutFile -Parent
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -Path $parent -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Step "Downloading: $(Split-Path $OutFile -Leaf)..."
    Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -ErrorAction Stop
}

# -------------------------------------------------------------------------
# 1. Disable Sleep / Power Settings (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'Disable Sleep Settings' -ScriptBlock {
    $disableSleepScript = Join-Path $ScriptDir 'disable_sleep.ps1'
    Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/disable_sleep.ps1' -OutFile $disableSleepScript
    & $disableSleepScript
}

# -------------------------------------------------------------------------
# 2. DNSFilter Agent Installation (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'DNSFilter Agent MSI Installation' -ScriptBlock {
    $dnsMsiPath = Join-Path $TempDir 'DNSFilter_Agent_Setup.msi'
    Invoke-ScriptDownload -Uri 'https://download.dnsfilter.com/User_Agent/Windows/DNSFilter_Agent_Setup.msi' -OutFile $dnsMsiPath

    $dnsArgs = @(
        '/i',
        "`"$dnsMsiPath`"",
        '/qn',
        'NKEY="423ffc54341e60e1f87fa94d"'
    )
    $dnsProcess = Start-Process -FilePath 'msiexec.exe' -ArgumentList $dnsArgs -Wait -PassThru
    if ($dnsProcess.ExitCode -notin @(0, 3010)) {
        Write-Warning "DNSFilter MSI exited with code $($dnsProcess.ExitCode) (Non-fatal, continuing)"
    }
}

# -------------------------------------------------------------------------
# 3. Windows Update (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'Windows Update Script' -ScriptBlock {
    $winUpdateScript = Join-Path $ScriptDir 'Windows_update.ps1'
    if (Test-Path -LiteralPath $winUpdateScript) {
        & $winUpdateScript
    } else {
        Write-Warning "Windows update script not found at $winUpdateScript, skipping."
    }
}

# -------------------------------------------------------------------------
# 4. JumpCloud Agent Installation (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'JumpCloud Windows Agent Enrollment' -ScriptBlock {
    $jcScriptPath = Join-Path $env:TEMP 'InstallWindowsAgent.ps1'
    Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/TheJumpCloud/support/master/scripts/windows/InstallWindowsAgent.ps1' -OutFile $jcScriptPath

    $jcConnectKey = 'jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g'
    & $jcScriptPath -JumpCloudConnectKey $jcConnectKey

    Write-Step 'Waiting 190 seconds for JumpCloud agent daemon to initialize...'
    Start-Sleep -Seconds 190
}

# -------------------------------------------------------------------------
# 5. SentinelOne EDR Installation (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'SentinelOne EDR Deployment' -ScriptBlock {
    $s1Script = Join-Path $ScriptDir 'Download_S1.ps1'
    Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/Download_S1.ps1' -OutFile $s1Script
    & $s1Script

    $s1Installer = Join-Path $TempDir 'SentinelOneInstaller.exe'
    if (Test-Path -LiteralPath $s1Installer) {
        $s1Token = 'eyJ1cmwiOiAiaHR0cHM6Ly91c2VhMS0wMTguc2VudGluZWxvbmUubmV0IiwgInNpdGVfa2V5IjogIjY3ODVmZjg0MGEwZDMzODYifQ=='
        Start-Process -FilePath $s1Installer -ArgumentList @('-q', '-t', $s1Token) -Wait
    } else {
        Write-Warning "SentinelOne installer not found at $s1Installer"
    }
}

# -------------------------------------------------------------------------
# 6. Secondary Deployment Scripts & RunOnce Registration (Continues on Error)
# -------------------------------------------------------------------------
Invoke-SafeStep -StepName 'Secondary Scripts & RunOnce Registration' -ScriptBlock {
    Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/Join-TurnerDomain_second_try.ps1' -OutFile (Join-Path $ScriptDir 'Join-TurnerDomain_second_try.ps1')
    Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/Join-TurnerDomain_second_try.bat' -OutFile (Join-Path $ScriptDir 'Join-TurnerDomain_second_try.bat')

    $scriptPart5 = Join-Path $ScriptDir 'ScriptPart5.ps1'
    Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/ScriptPart5.ps1' -OutFile $scriptPart5

    # RunOnce must call powershell.exe with -ExecutionPolicy Bypass to execute .ps1 scripts
    $runOnceCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPart5`""
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    Set-ItemProperty -Path $runOncePath -Name 'MyScriptPart5' -Value $runOnceCmd -Type String -Force -ErrorAction SilentlyContinue
    Write-Step "RunOnce post-reboot entry created: MyScriptPart5 (PowerShell .ps1)"
}

# -------------------------------------------------------------------------
# 7. Domain Join Decision (Interactive or Unattended)
# -------------------------------------------------------------------------
$doJoinDomain = $false

if ($JoinDomain) {
    $doJoinDomain = $true
} elseif ($SkipDomainJoin) {
    $doJoinDomain = $false
} else {
    Write-Host ''
    Write-Host '===================================================' -ForegroundColor Yellow
    Write-Host ' TURNER INDUSTRIES DOMAIN JOIN CONFIGURATION' -ForegroundColor Yellow
    Write-Host '===================================================' -ForegroundColor Yellow
    try {
        $response = Read-Host -Prompt 'Do you want to join to the domain? (Y/N)'
        if ($response -match '^[Yy]') {
            $doJoinDomain = $true
        }
    } catch {
        Write-Warning "Could not read user response (unattended console). Defaulting to JumpCloud-only."
    }
}

# -------------------------------------------------------------------------
# 8. Execution Path: YES (Full Domain) vs NO (JC Only) (Continues on Error)
# -------------------------------------------------------------------------
if ($doJoinDomain) {
    Write-Host 'Selection: Joining Turner Domain (Full JumpCloud Managed)...' -ForegroundColor Green
    
    Invoke-SafeStep -StepName 'Add Computer to Full JC Managed' -ScriptBlock {
        $fullJcScript = Join-Path $ScriptDir 'add_computer_to_full_JC_managed.ps1'
        Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/add_computer_to_full_JC_managed.ps1' -OutFile $fullJcScript
        & $fullJcScript
    }

    Invoke-SafeStep -StepName 'Join Domain with LAPS' -ScriptBlock {
        $domainScript = Join-Path $ScriptDir 'Jointodomainwithladps.ps1'
        Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/Jointodomainwithladps.ps1' -OutFile $domainScript
        & $domainScript
    }

    Write-Step 'Waiting 45 seconds for domain synchronization...'
    Start-Sleep -Seconds 45

    Invoke-SafeStep -StepName 'Provision Default User VPN Phonebook (.pbk)' -ScriptBlock {
        $pbkDir = 'C:\Users\Default\AppData\Roaming\Microsoft\Network\Connections\Pbk'
        if (-not (Test-Path -LiteralPath $pbkDir)) {
            New-Item -Path $pbkDir -ItemType Directory -Force -ErrorAction SilentlyContinue | Out-Null
        }
        Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/rasphone.pbk' -OutFile (Join-Path $pbkDir 'rasphone.pbk')
    }

    # Cleanup sensitive temporary domain scripts
    Write-Step 'Cleaning up temporary provisioning scripts...'
    Remove-Item -Path (Join-Path $ScriptDir 'add_computer_to_full_JC_managed.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $ScriptDir 'Jointodomainwithladps.ps1') -Force -ErrorAction SilentlyContinue

} else {
    Write-Host 'Selection: JumpCloud Only Managed (No Domain Join)...' -ForegroundColor Yellow
    
    Invoke-SafeStep -StepName 'Add to JC Only Managed' -ScriptBlock {
        $jcOnlyScript = Join-Path $ScriptDir 'add_to_jc_only_managed.ps1'
        Invoke-ScriptDownload -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/add_to_jc_only_managed.ps1' -OutFile $jcOnlyScript
        & $jcOnlyScript
    }
}

# -------------------------------------------------------------------------
# 9. Reboot (Guaranteed to execute even if prior steps logged warnings)
# -------------------------------------------------------------------------
if ($SkipReboot) {
    Write-Step 'SkipReboot flag detected. SetupComplete finished without reboot.'
} else {
    Write-Host 'SetupComplete sequence complete. System is rebooting now...' -ForegroundColor Green
    Restart-Computer -Force -ErrorAction SilentlyContinue
}
