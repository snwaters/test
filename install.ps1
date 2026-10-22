<#
================================================================================
.SYNOPSIS
    Automated Active Directory Domain Join with Pre-Join Computer Account Cleanup
    and Post-Join Security Group Provisioning.

.DESCRIPTION
    1. Discovers and pins to a healthy Domain Controller via DNS with retries.
    2. Searches Active Directory for any pre-existing/stale computer account
       matching the current hostname and deletes it (.NET ADSI) to eliminate
       "Account already exists", duplicate SPN, or "Access denied" join conflicts.
    3. Joins the domain into the target OU targeting the pinned DC.
    4. Adds the newly joined computer to designated security groups on the same DC.
================================================================================
#>

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

# --- CONFIGURATION ---
$Domain   = "turner-industries.com"
$User     = "turner-nt\srv-sccmjointoad"
$Pass   = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred   = New-Object System.Management.Automation.PSCredential($User, $Pass)

$TargetOU = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"
$TargetGroups = @(
    "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"
)

$ComputerName = $env:COMPUTERNAME

# --- STEP 1: ROBUST DC DISCOVERY (With Retries) ---
Write-Host "Locating Domain Controller for $Domain..."
$TargetDCHostname = $null
$Attempt = 0
$MaxAttempts = 15

while ($null -eq $TargetDCHostname -and $Attempt -lt $MaxAttempts) {
    $Attempt++
    try {
        # 1. Query DNS for the Domain's IP addresses (DCs)
        $DomainDNS = [System.Net.Dns]::GetHostEntry($Domain)
        
        # 2. Select first available IP
        $BestDCIP  = $DomainDNS.AddressList[0].IPAddressToString
        
        # 3. Resolve that IP to real Hostname (Required for Kerberos SPN / LDAP binding)
        $DCHostEntry = [System.Net.Dns]::GetHostEntry($BestDCIP)
        $TargetDCHostname = $DCHostEntry.HostName

        Write-Host "Success! Pinned to Domain Controller: $TargetDCHostname ($BestDCIP)"
    }
    catch {
        Write-Warning "Attempt $($Attempt)/$($MaxAttempts): DNS not ready yet. Waiting 3s..."
        Start-Sleep -Seconds 3
    }
}

# --- SAFETY CHECK ---
if ([string]::IsNullOrEmpty($TargetDCHostname)) {
    Write-Error "CRITICAL FAILURE: Could not resolve a Domain Controller after $MaxAttempts attempts."
    Write-Error "Verify network link, DHCP lease, and DNS server configuration."
    exit 1
}

# --- STEP 2: ACTIVE DIRECTORY PRE-JOIN CLEANUP (Pure .NET ADSI - Zero RSAT Dependency) ---
# Deletes any existing computer account matching this hostname across the domain
# to prevent "Account Already Exists", duplicate SPN, or "Access Denied" join conflicts.
Write-Host "Searching Active Directory for existing computer account '$ComputerName' on $TargetDCHostname..."

$PlainUser = $Cred.UserName
$PlainPass = $Cred.GetNetworkCredential().Password

try {
    # 1. Determine Search Base DN (Search entire domain root to catch stale objects in any OU)
    $DomainDN = (($Domain.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
    $SearchLdapPath = "LDAP://$TargetDCHostname/$DomainDN"
    
    # 2. Bind to Directory with explicit credentials targeted to pinned DC
    $SearchRoot = New-Object System.DirectoryServices.DirectoryEntry($SearchLdapPath, $PlainUser, $PlainPass, "Secure")
    
    # 3. Create DirectorySearcher to locate the computer by sAMAccountName ($ComputerName$)
    $Searcher = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $Searcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $ComputerName + '$))'
    $Searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $Searcher.PageSize = 10
    
    $ExistingComputerResult = $Searcher.FindOne()
    
    if ($null -ne $ExistingComputerResult) {
        $ExistingDN = $ExistingComputerResult.Properties["distinguishedname"][0]
        Write-Warning "CONFLICT DETECTED: Found existing computer object in AD: $ExistingDN"
        Write-Host "Deleting stale computer object from $TargetDCHostname before joining to ensure a clean state..."
        
        # 4. Bind directly to the computer object to invoke deletion
        $ComputerEntry = $ExistingComputerResult.GetDirectoryEntry()
        $ComputerEntry.Username = $PlainUser
        $ComputerEntry.Password = $PlainPass
        $ComputerEntry.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure
        
        # DeleteTree() deletes the computer account and all nested leaf objects (e.g., BitLocker keys, TPM records)
        $ComputerEntry.DeleteTree()
        
        Write-Host "Success: Stale computer account deleted from Active Directory ($TargetDCHostname)."
        
        # 5. Brief pause to allow local DC database to commit tombstone before Add-Computer executes
        Write-Host "Waiting 3s for directory commit to settle..."
        Start-Sleep -Seconds 3
    } else {
        Write-Host "No existing computer account found with name '$ComputerName'. Clean state confirmed. Proceeding to join."
    }
}
catch {
    Write-Warning "Notice during AD computer cleanup: $_"
    if ($_.Exception.InnerException) { Write-Warning $_.Exception.InnerException.Message }
    Write-Host "Continuing with domain join attempt..."
}

# --- STEP 3: JOIN DOMAIN (Targeting the Pinned DC) ---
Write-Host "Joining Domain '$Domain' into '$TargetOU' using $TargetDCHostname..."
try {
    Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Server $TargetDCHostname -ErrorAction Stop
    Write-Host "Success: Computer '$ComputerName' successfully joined to domain '$Domain'."
}
catch {
    Write-Error "Join failed. Error: $_"
    exit 1
}

# --- STEP 4: ADD TO AD SECURITY GROUPS (Targeting SAME DC via ADSI) ---
Write-Host "Assigning Computer to AD Groups on $TargetDCHostname..."

$ComputerDN = "CN=$ComputerName,$TargetOU"
$PlainUser  = $Cred.UserName
$PlainPass  = $Cred.GetNetworkCredential().Password

foreach ($GroupDN in $TargetGroups) {
    if ([string]::IsNullOrWhiteSpace($GroupDN)) { continue }
    try {
        Write-Host "Adding to group: $GroupDN"
        $LdapPath    = "LDAP://$TargetDCHostname/$GroupDN"
        $GroupObject = New-Object System.DirectoryServices.DirectoryEntry($LdapPath, $PlainUser, $PlainPass, "Secure")

        # Invoke LDAP 'Add' method with the computer's distinguished name
        $GroupObject.Invoke("Add", "LDAP://$ComputerDN")
        $GroupObject.CommitChanges()

        Write-Host "Success: Added '$ComputerName' to group '$GroupDN' via $TargetDCHostname."
    }
    catch {
        Write-Error "Failed to add to group '$GroupDN'. Error: $_"
        if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
    }
}

Write-Host "================================================================="
Write-Host "Domain Join and Active Directory Provisioning Completed Successfully."
Write-Host "================================================================="
