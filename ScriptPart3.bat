
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"
rem start /wait msiexec /i %~dp0jcagent-msi-signed.msi /quiet JCINSTALLERARGUMENTS="-k jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g /VERYSILENT /SUPPRESSMSGBOXES"
start /wait powershell.exe -Command "Invoke-WebRequest -Uri https://raw.githubusercontent.com/snwaters/test/refs/heads/main/ScriptPart4.bat.ps1 -OutFile C:\osdcloud\Scripts\SetupComplete\ScriptPart4.bat.ps1
echo Continuing to part 3 after reboot...
        reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" /v "MyScriptPart4" /t REG_SZ /d "C:\osdcloud\Scripts\SetupComplete\ScriptPart4.bat" /f
del C:\osdcloud\Scripts\Shutdown\create_unattended.ps1
shutdown /r /f /t 0
