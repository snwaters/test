:: ScriptPart2.bat (to be run after reboot)
      
        echo This is part 2, running after reboot.
        :: Continue with the rest of your operations

start /wait msiexec /i %~dp0jcagent-msi-signed.msi /quiet JCINSTALLERARGUMENTS="-k jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g /VERYSILENT /SUPPRESSMSGBOXES"
del C:\osdcloud\Config\Scripts\Shutdown\create_unattended.ps1

timeout /t 60

start /wait powershell.exe -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/snwaters/test/refs/heads/main/install.ps1 -OutFile C:\osdcloud\Scripts\SetupComplete\install.ps1; #.\install.ps1"

cmd /c Dism.exe /online /Enable-Feature /FeatureName:Microsoft-Hyper-V /All /NoRestart


start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Enable_virtual_setting in bios.ps1"

REG ADD "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\DeviceGuard" /V EnableVirtualizationBasedSecurity /T REG_DWORD /D 1 /F

REG ADD "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\DeviceGuard" /V RequirePlatformSecurityFeatures /T REG_DWORD /D 3 /F

REG ADD "HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\LSA" /V LsaCfgFlags /T REG_DWORD /D 1 /F

START /WAIT "BGinfo" "C:\osdcloud\Scripts\SetupComplete\BGInfo_11_2021\install.bat"

winget install -e --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --source winget --scope machine

winget install -e --id Google.GoogleDrive --silent --accept-package-agreements --accept-source-agreements --source winget --scope machine

winget install -e --id Lenovo.SystemUpdate --silent --accept-package-agreements --accept-source-agreements --source winget --scope machine

winget install -e --id Lenovo.DockManager --silent --accept-package-agreements --accept-source-agreements --source winget --scope machine

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\activation.ps1"

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"

