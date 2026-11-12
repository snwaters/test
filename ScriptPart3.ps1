<#
.SYNOPSIS
    OSDCloud scriptpart3.ps1 Provisioning Script (Converted from Batch)
.DESCRIPTION
    Executes post-OS deployment tasks: downloads companion scripts, runs
    updates, registers post-reboot RunOnce continuation, and restarts.
#>

# Continue execution on non-fatal errors or network timeouts
$ErrorActionPreference = 'Continue'

# Ensure destination directories exist prior to web downloads
$setupDir = 'C:\osdcloud\Scripts\SetupComplete'
if (-not (Test-Path -Path $setupDir)) {
    New-Item -ItemType Directory -Path $setupDir -Force | Out-Null
}


Write-Host "Downloading disable_sleep.ps1..." -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/disable_sleep.ps1' -OutFile 'C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1' -UseBasicParsing

Write-Host "Executing C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1..." -ForegroundColor Cyan
if (Test-Path -Path 'C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1') {
    & 'C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1'
} else {
    Write-Warning "Script not found: C:\osdcloud\Scripts\SetupComplete\disable_sleep.ps1"
}

Write-Host "Executing C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1..." -ForegroundColor Cyan
if (Test-Path -Path 'C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1') {
    & 'C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1'
} else {
    Write-Warning "Script not found: C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"
}

# [OPTIONAL] JumpCloud Agent Installer (Enable in toolbar if required):
# $msiPath = Join-Path $PSScriptRoot "jcagent-msi-signed.msi"
# Start-Process -FilePath "msiexec.exe" -ArgumentList @('/i', ('"' + $msiPath + '"'), '/quiet', '/norestart', 'JCINSTALLERARGUMENTS="-k jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g /VERYSILENT /SUPPRESSMSGBOXES"') -Wait -NoNewWindow

Write-Host "Downloading ScriptPart4.ps1..." -ForegroundColor Cyan
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/snwaters/test/refs/heads/main/ScriptPart4.ps1' -OutFile 'C:\osdcloud\Scripts\SetupComplete\ScriptPart4.ps1' -UseBasicParsing

Write-Host "Continuing to part 4 after reboot..." -ForegroundColor Yellow

# Configure RunOnce for post-reboot continuation
Write-Host "Continuing to part 4 after reboot..." -ForegroundColor Yellow
try {
    $runOncePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
    if (-not (Test-Path -Path $runOncePath)) {
        New-Item -Path $runOncePath -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $part4Command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\ScriptPart4.ps1"'
    Set-ItemProperty -Path $runOncePath -Name 'MyScriptPart4' -Value $part4Command -Force -ErrorAction Continue
    Write-Host "Registered RunOnce entry: MyScriptPart4 -> $part4Command" -ForegroundColor Green
} catch {
    Write-Warning "Failed to set RunOnce registry property: $_"
}

Write-Host "Cleaning up create_unattended.ps1..." -ForegroundColor DarkGray
if (Test-Path -Path 'C:\osdcloud\Scripts\Shutdown\create_unattended.ps1') {
    Remove-Item -Path 'C:\osdcloud\Scripts\Shutdown\create_unattended.ps1' -Force -ErrorAction SilentlyContinue
}

Write-Host "Rebooting computer to trigger RunOnce sequence..." -ForegroundColor Green
Restart-Computer -Force
