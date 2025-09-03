
start /wait powershell.exe -NoProfile -ExecutionPolicy Bypass -File "C:\osdcloud\Scripts\SetupComplete\Windows_update.ps1"
pause
shutdown /r /f /t 0
