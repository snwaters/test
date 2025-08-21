# install-apps.ps1

# Install Jumpcloud

Start-Process msiexec.exe -ArgumentList 'googlechromestandaloneenterprise64.msi  /qn ALLUSERS=2 REBOOT=REALLYSUPPRESS' -Wait
pause
