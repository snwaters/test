# install-apps.ps1

# Install Jumpcloud

#Start-Process msiexec.exe -ArgumentList 'googlechromestandaloneenterprise64.msi  /qn ALLUSERS=2 REBOOT=REALLYSUPPRESS' -Wait

# --- CONFIGURATION ---
$Domain = "turner-industries.com"
$User   = "turner-nt\srv-sccmjointoad"
$Pass   = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

$TargetOU = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"
$GroupDN   = "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"

# --- STEP 1: FIND DC USING NLTEST (More Robust) ---
Write-Host "Locating Domain Controller for $Domain..."

# nltest /dsgetdc finds the DC for the specific domain
# We capture the output and parse it for the DC name
$NltestOutput = nltest /dsgetdc:$Domain /force 2>$null

# Regex to find the pattern "DC: \\Hostname"
if ($NltestOutput -match "DC: \\\\([^\s]+)") {
    $TargetDCHostname = $matches[1]
    Write-Host "Pinned to Domain Controller: $TargetDCHostname"
}
else {
    # FALLBACK: If discovery fails, you must have a hardcoded fallback or exit
    Write-Error "Could not locate a Domain Controller via nltest. DNS might be unreachable."
    # Optional: Hardcode a fallback here if you have a known stable DC
    # $TargetDCHostname = "dc01.corp.contoso.com"
    exit 1
}

# --- STEP 2: JOIN DOMAIN (Targeting Found DC) ---
Write-Host "Joining Domain using $TargetDCHostname..."

# -Server forces the join to this specific DC
Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Server $TargetDCHostname -ErrorAction Stop

# --- STEP 3: ADD TO GROUP (Targeting SAME DC) ---
Write-Host "Adding Computer to AD Group..."

$ComputerName = $env:COMPUTERNAME
$ComputerDN   = "CN=$ComputerName,$TargetOU"

try {
    # Connect to the Group object on the SPECIFIC DC we just used
    $LdapPath = "LDAP://$TargetDCHostname/$GroupDN"
    
    $GroupObject = [ADSI]$LdapPath
    $GroupObject.psbase.Options.Credentials = $Cred

    # Add the computer member
    $GroupObject.Add("LDAP://$ComputerDN")
    $GroupObject.SetInfo()
    
    Write-Host "Success: Added to group via $TargetDCHostname."
}
catch {
    Write-Error "Failed to add to group. Error: $_"
}

# --- STEP 4: REBOOT ---
#Start-Sleep -Seconds 5
#Restart-Computer -Force
