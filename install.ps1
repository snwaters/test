# install-apps.ps1

# Install Jumpcloud

#Start-Process msiexec.exe -ArgumentList 'googlechromestandaloneenterprise64.msi  /qn ALLUSERS=2 REBOOT=REALLYSUPPRESS' -Wait

$Domain = "turner-industries.com"
$User   = "turner-nt\srv-sccmjointoad"
$Pass   = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

# The specific OU where the computer should land
$TargetOU = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"

# Join the domain with the OUPath parameter
Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Restart
