# --- CONFIGURATION ---
$Domain = "turner-industries.com"
$User   = "turner-nt\srv-sccmjointoad"
$Pass   = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

$TargetOU = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"
$GroupDN   = "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"

# --- STEP 1: ROBUST DC DISCOVERY (With Retries) ---
Write-Host "Locating Domain Controller for $Domain..."
$TargetDCHostname = $null
$Attempt = 0
$MaxAttempts = 15

# Loop until we find a DC or run out of attempts
while ($null -eq $TargetDCHostname -and $Attempt -lt $MaxAttempts) {
    $Attempt++
    try {
        # 1. Ask DNS for the Domain's IP addresses (which are the DCs)
        $DomainDNS = [System.Net.Dns]::GetHostEntry($Domain)
        
        # 2. Pick the first IP found
        $BestDCIP  = $DomainDNS.AddressList[0].IPAddressToString
        
        # 3. Resolve that IP to its real Hostname (Required for Kerberos)
        $DCHostEntry = [System.Net.Dns]::GetHostEntry($BestDCIP)
        $TargetDCHostname = $DCHostEntry.HostName

        Write-Host "Success! Pinned to DC: $TargetDCHostname ($BestDCIP)"
    }
    catch {
        Write-Warning "Attempt $($Attempt)/$($MaxAttempts): DNS not ready yet. Waiting 3s..."
        Start-Sleep -Seconds 3
    }
}

# --- SAFETY CHECK ---
if ([string]::IsNullOrEmpty($TargetDCHostname)) {
    Write-Error "CRITICAL FAILURE: Could not resolve a Domain Controller after $MaxAttempts attempts."
    Write-Error "Check network cable and DNS settings."
    exit 1 # Stop the script so we don't throw 'Null' errors below
}

# --- STEP 2: JOIN DOMAIN ---
Write-Host "Joining Domain using $TargetDCHostname..."
try {
    Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Server $TargetDCHostname -ErrorAction Stop
}
catch {
    Write-Error "Join failed. Error: $_"
    exit 1
}

# --- STEP 3: ADD TO GROUP (Targeting SAME DC) ---
Write-Host "Adding Computer to AD Group on $TargetDCHostname..."

$ComputerName = $env:COMPUTERNAME
$ComputerDN   = "CN=$ComputerName,$TargetOU"

try {
    # 1. We need to unwrap the password from the SecureString for ADSI
    #    (ADSI requires a plain text password string, not a credential object)
    $PlainUser = $Cred.UserName
    $PlainPass = $Cred.GetNetworkCredential().Password

    # 2. Construct the LDAP Path
    $LdapPath = "LDAP://$TargetDCHostname/$GroupDN"

    # 3. Create the connection object using the explicit .NET Constructor
    #    Arguments: Path, Username, Password, AuthenticationType
    $GroupObject = New-Object System.DirectoryServices.DirectoryEntry($LdapPath, $PlainUser, $PlainPass, "Secure")

    # 4. Add the computer to the group
    $GroupObject.Invoke("Add", "LDAP://$ComputerDN")
    
    # 5. Save changes (Commit)
    $GroupObject.CommitChanges()
    
    Write-Host "Success: Added to group via $TargetDCHostname."
}
catch {
    Write-Error "Failed to add to group. Error: $_"
    # Detailed error info for debugging
    if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
}
