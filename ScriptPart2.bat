:: ScriptPart2.bat (to be run after reboot)
      
        echo This is part 2, running after reboot.
        :: Continue with the rest of your operations

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Delete_cached_os.ps1"

powercfg /x -standby-timeout-ac 0



rem timeout /t 60

start /wait powershell.exe -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/snwaters/test/refs/heads/main/install.ps1 -OutFile C:\osdcloud\Scripts\SetupComplete\install.ps1
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\install.ps1"

rem start /wait powershell.exe -Command "Add-LocalGroupMember -Group "Administrators" -Member "Turner-nt\Desktop_admins"

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

 echo Continuing to part 3 after reboot...
        reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v "MyScriptPart3" /t REG_SZ /d "C:\osdcloud\Scripts\SetupComplete\ScriptPart3.bat" /f

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"

rem CALL C:\osdcloud\Scripts\SetupComplete\SentinalOne\install.bat

shutdown /r /f /t 0

