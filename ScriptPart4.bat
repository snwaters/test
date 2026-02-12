start /wait powershell.exe -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/snwaters/test/refs/heads/main/install.ps1 -OutFile C:\osdcloud\Scripts\SetupComplete\install.ps1
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\install.ps1"

start /wait powershell.exe -Command "Invoke-WebRequest -Uri "https://download.dnsfilter.com/User_Agent/Windows/DNSFilter_Agent_Setup.msi" -OutFile "C:\windows\temp\DNSFilter_Agent_Setup.msi"
start /wait msiexec /qn /i "C:\windows\temp\DNSFilter_Agent_Setup.msi" NKEY="423ffc54341e60e1f87fa94d"

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"

start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "cd $env:temp | Invoke-Expression; Invoke-RestMethod -Method Get -URI https://raw.githubusercontent.com/TheJumpCloud/support/master/scripts/windows/InstallWindowsAgent.ps1 -OutFile InstallWindowsAgent.ps1 | Invoke-Expression; ./InstallWindowsAgent.ps1 -JumpCloudConnectKey "jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g"

timeout /t 30

start /wait powershell.exe -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/snwaters/test/refs/heads/main/add_computer_to_full_JC_managed.ps1 -OutFile C:\osdcloud\Scripts\SetupComplete\add_computer_to_full_JC_managed.ps1
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\add_computer_to_full_JC_managed.ps1"

shutdown /r /f /t 0
