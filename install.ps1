# install-apps.ps1

# Install Jumpcloud

Start-Process msiexec.exe -ArgumentList 'googlechromestandaloneenterprise64.msi  /qn ALLUSERS=2 REBOOT=REALLYSUPPRESS' -Wait

$domain = "turner-nt"
$user = "turner-nt\srv-jointoad"
$password = "YourPassword" | ConvertTo-SecureString -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($user, $password)

Add-Computer -DomainName $domain -Credential $credential -Restart -Force
