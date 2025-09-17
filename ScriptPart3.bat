
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"
start /wait msiexec /i %~dp0jcagent-msi-signed.msi /quiet JCINSTALLERARGUMENTS="-k jcc_eyJwdWJsaWNLaWNrc3RhcnRVcmwiOiJodHRwczovL2tpY2tzdGFydC5qdW1wY2xvdWQuY29tIiwicHJpdmF0ZUtpY2tzdGFydFVybCI6Imh0dHBzOi8vcHJpdmF0ZS1raWNrc3RhcnQuanVtcGNsb3VkLmNvbSIsImNvbm5lY3RLZXkiOiIzYzZmZTU3MDA3ZWVmNzNmOTg2NmM4MTcxNTU0Y2E2MWRkYzViNmM0In0g /VERYSILENT /SUPPRESSMSGBOXES"
del C:\osdcloud\Scripts\Shutdown\create_unattended.ps1
shutdown /r /f /t 0
