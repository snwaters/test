# install-apps.ps1

# Install Jumpcloud

#Start-Process msiexec.exe -ArgumentList 'googlechromestandaloneenterprise64.msi  /qn ALLUSERS=2 REBOOT=REALLYSUPPRESS' -Wait

# --- CONFIGURATION ---
$Domain = "turner-industries.com"
$User   = "turner-nt\srv-sccmjointoad"
$Pass   = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

# Computer Object will be added to All Computers > Baton Rouge
$TargetOU = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"

# Adds the computer the group to get a device certificate
$GroupDN   = "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"

# --- STEP 1: JOIN DOMAIN ---
Write-Host "Joining Domain..."
# Note: We removed the '-Restart' switch so the script keeps running!
Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -ErrorAction Stop

# --- STEP 2: CALCULATE COMPUTER DN ---
# Since we know the Computer Name and the Target OU, we can build the DN manually.
$ComputerName = $env:COMPUTERNAME
$ComputerDN   = "CN=$ComputerName,$TargetOU"

# Pause the script for 10 seconds for domain replication to happen
Start-Sleep -Seconds 10

# --- STEP 3: ADD TO GROUP VIA ADSI ---
Write-Host "Adding Computer to AD Group..."
try {
    # Connect to the Group object in AD using the Service Account credentials
    $GroupObject = [ADSI]"LDAP://$GroupDN"
    $GroupObject.psbase.Options.Credentials = $Cred

    # Add the computer (LDAP path) to the group
    $GroupObject.Add("LDAP://$ComputerDN")
    
    # Save changes (SetInfo is required for ADSI to commit)
    $GroupObject.SetInfo()
    Write-Host "Successfully added $ComputerName to group."
}
catch {
    Write-Error "Failed to add to group. Error: $_"
}

# --- STEP 4: REBOOT ---
#Write-Host "Restarting in 5 seconds..."
#Start-Sleep -Seconds 5
#Restart-Computer -Force
