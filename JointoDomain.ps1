<#
================================================================================
.SYNOPSIS
    Automated Active Directory Domain Join with Pre-Flight Domain Membership
    Check, Secure LDAP (LDAPS) Account Cleanup, and Post-Join Group Provisioning.

.DESCRIPTION
    0. PRE-FLIGHT CHECK: Checks if the local machine is already joined to the
       target domain (via Win32_ComputerSystem CIM). Prevents redundant executions
       and protects against self-destructive AD account deletion.
    1. Discovers and pins to a healthy Domain Controller via DNS with retries.
    2. Searches Active Directory for any pre-existing/stale computer account
       matching the current hostname and deletes it using SECURE LDAP (LDAPS / Port 636)
       over .NET ADSI to eliminate "Account already exists", duplicate SPN, or
       "Access denied" join conflicts while encrypting all directory traffic.
    3. Joins the domain into the target OU targeting the pinned DC.
    4. Adds the newly joined computer to designated security groups on the same
       pinned DC over Secure LDAP (LDAPS).
================================================================================
#>

[CmdletBinding()]
param(
    [switch]$ForceRejoin = $false
)

$ErrorActionPreference = "Stop"

# --- CONFIGURATION ---
$Domain       = "turner-industries.com"
# Plaintext SecureString (Note: Use GMSA or SCCM Task Sequence variables in production)
$User = "turner-nt\srv-sccmjointoad"
$Pass = "cbXHmpRSCT7zd8f7CEKP" | ConvertTo-SecureString -AsPlainText -Force
$Cred = New-Object System.Management.Automation.PSCredential($User, $Pass)

$TargetOU     = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"
$TargetGroups = @(
    "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"
)

# Secure LDAP (LDAPS) Settings
$UseSecureLdap = $true # Enforce TLS/SSL encryption for directory operations
$LdapPort      = 636     # Standard LDAPS: 636, LDAP: 389

$ComputerName = $env:COMPUTERNAME

# Configure .NET ADSI Authentication Types
# SecureSocketsLayer (0x2) mandates TLS/SSL over port 636; Secure (0x1) enables Kerberos/NTLM signing
$LdapAuthType = if ($UseSecureLdap) {
    [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer -bor [System.DirectoryServices.AuthenticationTypes]::Secure
} else {
    [System.DirectoryServices.AuthenticationTypes]::Secure
}

# ==============================================================================
# --- STEP 0: PRE-FLIGHT DOMAIN MEMBERSHIP CHECK ---
# ==============================================================================
# Using CIM (with WMI fallback) - Zero RSAT requirement, works on Windows 10/11 & Server.
Write-Host "Checking current domain membership for '$ComputerName'..." -ForegroundColor Cyan

$CurrentSystem = $null
try {
    $CurrentSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
}
catch {
    # Fallback for environments where CIM is restricted
    $CurrentSystem = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
}

$IsJoined      = $false
$CurrentDomain = ""

if ($null -ne $CurrentSystem) {
    $IsJoined      = [bool]$CurrentSystem.PartOfDomain
    $CurrentDomain = $CurrentSystem.Domain
}

if ($IsJoined) {
    Write-Host "Current Status: Computer is joined to domain '$CurrentDomain'." -ForegroundColor Yellow
    
    # Check if joined to the EXACT TARGET domain
    if ($CurrentDomain -ieq $Domain) {
        Write-Host "Computer '$ComputerName' is ALREADY joined to target domain '$Domain'." -ForegroundColor Green
        
        # Optional: Verify Domain Controller Secure Channel trust relationship
        Write-Host "Verifying AD secure channel / machine trust relationship..." -ForegroundColor Gray
        try {
            $ChannelOK = Test-ComputerSecureChannel -ErrorAction SilentlyContinue
            if ($ChannelOK) {
                Write-Host "Secure channel test PASSED. Machine account is healthy in AD." -ForegroundColor Green
            } else {
                Write-Warning "Secure channel test returned FALSE or unhealthy. Domain trust may be broken."
            }
        }
        catch {
            Write-Warning "Could not verify secure channel: $_"
        }

        if ($ForceRejoin) {
            Write-Warning "ForceRejoin switch specified. Proceeding with clean re-join process..."
        } else {
            Write-Host "=================================================================" -ForegroundColor Green
            Write-Host "SUCCESS: Machine is already a member of '$Domain'. No action needed." -ForegroundColor Green
            Write-Host "Exiting cleanly (Exit Code 0). Safe from redundant join or AD deletion." -ForegroundColor Green
            Write-Host "=================================================================" -ForegroundColor Green
            exit 0
        }
    }
    else {
        # Joined to a DIFFERENT domain
        Write-Warning "CONFLICT: Computer is currently joined to a different domain: '$CurrentDomain' (Target is '$Domain')."
        if (-not $ForceRejoin) {
            Write-Error "Halting. To disjoin from '$CurrentDomain' and rejoin '$Domain', re-run with -ForceRejoin or disjoin manually."
            exit 2
        }
        Write-Warning "ForceRejoin switch active: Will attempt migration from '$CurrentDomain' to '$Domain'."
    }
}
else {
    $Workgroup = if ($CurrentSystem.Workgroup) { $CurrentSystem.Workgroup } else { "WORKGROUP" }
    Write-Host "Confirmed: Computer is in workgroup '$Workgroup' (Not joined to any domain)." -ForegroundColor Green
    Write-Host "Proceeding with automated domain join to '$Domain'..." -ForegroundColor Cyan
}

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
        
        # 3. Resolve that IP to real Hostname (Required for TLS/SSL Certificate Subject Name and Kerberos SPN)
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

# --- STEP 2: ACTIVE DIRECTORY PRE-JOIN CLEANUP (Pure .NET ADSI over SECURE LDAP - Zero RSAT Dependency) ---
# Deletes any existing computer account matching this hostname across the domain via LDAPS (Port 636)
# to prevent "Account Already Exists", duplicate SPN, or "Access Denied" join conflicts with encrypted transport.
Write-Host "Searching Active Directory for '$ComputerName' on $TargetDCHostname via Secure LDAP (Port $LdapPort)..." -ForegroundColor Cyan

$PlainUser = $Cred.UserName
$PlainPass = $Cred.GetNetworkCredential().Password

try {
    # 1. Determine Search Base DN (Search entire domain root to catch stale objects in any OU)
    $DomainDN = (($Domain.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
    $SearchLdapPath = "LDAP://$($TargetDCHostname):$LdapPort/$DomainDN"
    
    # 2. Bind to Directory with explicit credentials targeted to pinned DC using Secure LDAP (TLS/SSL)
    $SearchRoot = New-Object System.DirectoryServices.DirectoryEntry($SearchLdapPath, $PlainUser, $PlainPass, $LdapAuthType)
    
    # 3. Create DirectorySearcher to locate the computer by sAMAccountName ($ComputerName$)
    $Searcher = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $Searcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $ComputerName + '$))'
    $Searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $Searcher.PageSize = 10
    
    $ExistingComputerResult = $Searcher.FindOne()
    
    if ($null -ne $ExistingComputerResult) {
        $ExistingDN = $ExistingComputerResult.Properties["distinguishedname"][0]
        Write-Warning "CONFLICT DETECTED: Found existing computer object in AD: $ExistingDN"
        Write-Host "Deleting stale computer object from $TargetDCHostname via Secure LDAP (LDAPS) before joining..." -ForegroundColor Yellow
        
        # 4. Bind directly to the computer object with LDAPS to invoke deletion
        $ComputerEntry = $ExistingComputerResult.GetDirectoryEntry()
        $ComputerEntry.Username = $PlainUser
        $ComputerEntry.Password = $PlainPass
        $ComputerEntry.AuthenticationType = $LdapAuthType
        
        # DeleteTree() deletes the computer account and all nested leaf objects (e.g., BitLocker keys, TPM records)
        $ComputerEntry.DeleteTree()
        
        Write-Host "Success: Stale computer account deleted from Active Directory ($TargetDCHostname) via Secure LDAP." -ForegroundColor Green
        
        # 5. Brief pause to allow local DC database to commit tombstone before Add-Computer executes
        Write-Host "Waiting 3s for directory commit to settle..."
        Start-Sleep -Seconds 3
    } else {
        Write-Host "No existing computer account found with name '$ComputerName'. Clean state confirmed via Secure LDAP. Proceeding to join."
    }
}
catch {
    Write-Warning "Notice during Secure LDAP (LDAPS) AD computer cleanup: $_"
    if ($_.Exception.InnerException) { Write-Warning $_.Exception.InnerException.Message }
    Write-Host "Continuing with domain join attempt..."
}

# --- STEP 3: JOIN DOMAIN (Targeting the Pinned DC) ---
Write-Host "Joining Domain '$Domain' into '$TargetOU' using $TargetDCHostname..."
try {
    Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Server $TargetDCHostname -ErrorAction Stop
    Write-Host "Success: Computer '$ComputerName' successfully joined to domain '$Domain'." -ForegroundColor Green
}
catch {
    Write-Error "Join failed. Error: $_"
    exit 1
}

# --- STEP 4: ADD TO AD SECURITY GROUPS (Targeting SAME DC via SECURE LDAP / LDAPS) ---
Write-Host "Assigning Computer to AD Groups on $TargetDCHostname via Secure LDAP (Port $LdapPort)..." -ForegroundColor Cyan

$ComputerDN = "CN=$ComputerName,$TargetOU"
$PlainUser  = $Cred.UserName
$PlainPass  = $Cred.GetNetworkCredential().Password

foreach ($GroupDN in $TargetGroups) {
    if ([string]::IsNullOrWhiteSpace($GroupDN)) { continue }
    try {
        Write-Host "Adding to group via LDAPS: $GroupDN"
        $GroupLdapPath = "LDAP://$($TargetDCHostname):$LdapPort/$GroupDN"
        $GroupObject   = New-Object System.DirectoryServices.DirectoryEntry($GroupLdapPath, $PlainUser, $PlainPass, $LdapAuthType)

        # Invoke LDAP 'Add' method targeting the pinned DC over Secure LDAP
        $ComputerLdapPath = "LDAP://$($TargetDCHostname):$LdapPort/$ComputerDN"
        $GroupObject.Invoke("Add", $ComputerLdapPath)
        $GroupObject.CommitChanges()

        Write-Host "Success: Added '$ComputerName' to group '$GroupDN' via $TargetDCHostname over Secure LDAP." -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to add to group '$GroupDN' via LDAPS. Error: $_"
        if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
    }
}

Write-Host "================================================================="
Write-Host "Domain Join and Active Directory Provisioning Completed Successfully (over Secure LDAP)."
Write-Host "================================================================="
