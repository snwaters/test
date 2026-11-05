<#
================================================================================
.SYNOPSIS
    Automated Active Directory Domain Join with Pre-Flight Domain Membership Check,
    Secure LDAP (LDAPS) with Automatic Standard LDAP Fallback, Account Cleanup,
    and Fault-Tolerant Security Group Provisioning.

.DESCRIPTION
    0. PRE-FLIGHT CHECK: Checks if the local machine is already joined to the
       target domain (via Win32_ComputerSystem CIM). Prevents redundant executions
       and protects against self-destructive AD account deletion.
    1. Discovers and pins to a healthy Domain Controller via DNS with retries.
    2. PROTOCOL SELECTION & RESILIENT BINDING:
       Attempts Secure LDAP (LDAPS / Port 636 with SSL/TLS).
       If LDAPS fails (untrusted CA cert or port 636 blocked), automatically falls back to standard LDAP (Port 389).
    3. Searches Active Directory for any pre-existing/stale computer account
       matching the current hostname and deletes it (.NET ADSI) to eliminate
       "Account already exists", duplicate SPN, or "Access denied" join conflicts.
    4. Joins the domain into the target OU targeting the pinned DC.
    5. AD SECURITY GROUPS WITH LDAPS -> LDAP FALLBACK:
       Attempts to assign the newly joined computer to designated security groups
       over Secure LDAP (LDAPS:636). If group modification fails under LDAPS,
       it automatically falls back to standard LDAP (Port 389) so group membership
       provisioning never fails.
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

# Secure LDAP (LDAPS) & Fallback Preferences
$UseSecureLdap      = $true # Preferred transport: LDAPS (TLS/SSL)
$PreferredLdapPort  = 636     # Standard LDAPS: 636
$AllowLdapFallback  = $true # Fall back to port 389 if LDAPS fails

$ComputerName = $env:COMPUTERNAME

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

# ==============================================================================
# --- STEP 2: LDAP PROTOCOL NEGOTIATION & PRE-JOIN ACCOUNT CLEANUP ---
# ==============================================================================
# Attempts Secure LDAP (Port 636) first. If LDAPS fails, automatically falls back
# to Standard LDAP (Port 389) so automation never breaks.
$PlainUser = $Cred.UserName
$PlainPass = $Cred.GetNetworkCredential().Password
$DomainDN  = (($Domain.Split('.') | ForEach-Object { "DC=$_" }) -join ',')

# Determine Active LDAP Endpoint & AuthType
$ActiveLdapPort = 389
$ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
$ActiveProtocol = "Standard LDAP (Port 389)"

if ($UseSecureLdap) {
    Write-Host "Testing Secure LDAP (LDAPS : $PreferredLdapPort) connection on $TargetDCHostname..." -ForegroundColor Cyan
    try {
        $LdapsTestPath = "LDAP://$($TargetDCHostname):$PreferredLdapPort/$DomainDN"
        $LdapsAuthType = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer -bor [System.DirectoryServices.AuthenticationTypes]::Secure
        $TestEntry     = New-Object System.DirectoryServices.DirectoryEntry($LdapsTestPath, $PlainUser, $PlainPass, $LdapsAuthType)
        
        # Force active socket connection and TLS handshake verification
        $null = $TestEntry.NativeObject
        
        $ActiveLdapPort = $PreferredLdapPort
        $ActiveAuthType = $LdapsAuthType
        $ActiveProtocol = "Secure LDAP (LDAPS Port $PreferredLdapPort / TLS Encrypted)"
        Write-Host "Success: Connected via $ActiveProtocol." -ForegroundColor Green
    }
    catch {
        Write-Warning "Secure LDAP (LDAPS : $PreferredLdapPort) connection failed to $TargetDCHostname."
        Write-Warning "Reason: $($_.Exception.Message)"
        
        if ($AllowLdapFallback) {
            Write-Warning "AUTOMATIC FALLBACK: Switching to Standard LDAP (Port 389) with Kerberos/NTLM authentication..."
            $ActiveLdapPort = 389
            $ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
            $ActiveProtocol = "Standard LDAP (Port 389 - Fallback Active)"
        }
        else {
            Write-Error "Secure LDAP connection failed and AllowLdapFallback is disabled. Halting."
            exit 1
        }
    }
}

Write-Host "Searching Active Directory for '$ComputerName' using $ActiveProtocol..." -ForegroundColor Cyan

try {
    # 1. Bind to Directory with explicit credentials targeted to pinned DC using active protocol
    $SearchLdapPath = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$DomainDN"
    $SearchRoot     = New-Object System.DirectoryServices.DirectoryEntry($SearchLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
    
    # 2. Locate computer by sAMAccountName ($ComputerName$)
    $Searcher             = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $Searcher.Filter      = '(&(objectCategory=computer)(sAMAccountName=' + $ComputerName + '$))'
    $Searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $Searcher.PageSize    = 10
    
    $ExistingComputerResult = $Searcher.FindOne()
    
    if ($null -ne $ExistingComputerResult) {
        $ExistingDN = $ExistingComputerResult.Properties["distinguishedname"][0]
        Write-Warning "CONFLICT DETECTED: Found existing computer object in AD: $ExistingDN"
        Write-Host "Deleting stale computer object from $TargetDCHostname via $ActiveProtocol before joining..." -ForegroundColor Yellow
        
        # 3. Bind directly to the computer object with active authentication to invoke deletion
        $ComputerEntry = $ExistingComputerResult.GetDirectoryEntry()
        $ComputerEntry.Username = $PlainUser
        $ComputerEntry.Password = $PlainPass
        $ComputerEntry.AuthenticationType = $ActiveAuthType
        
        # DeleteTree() deletes the computer account and all nested leaf objects (e.g. BitLocker keys, TPM records)
        $ComputerEntry.DeleteTree()
        
        Write-Host "Success: Stale computer account deleted from Active Directory ($TargetDCHostname) via $ActiveProtocol." -ForegroundColor Green
        
        # Brief pause to allow local DC database to commit tombstone before Add-Computer executes
        Write-Host "Waiting 3s for directory commit to settle..."
        Start-Sleep -Seconds 3
    } else {
        Write-Host "No existing computer account found with name '$ComputerName'. Clean state confirmed via $ActiveProtocol. Proceeding to join."
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
    Write-Host "Success: Computer '$ComputerName' successfully joined to domain '$Domain'." -ForegroundColor Green
}
catch {
    Write-Error "Join failed. Error: $_"
    exit 1
}

# ==============================================================================
# --- STEP 4: ADD TO AD SECURITY GROUPS (With LDAPS -> LDAP Auto-Fallback) ---
# ==============================================================================
Write-Host "Assigning Computer to AD Groups on $TargetDCHostname via $ActiveProtocol..." -ForegroundColor Cyan

$ComputerDN = "CN=$ComputerName,$TargetOU"

foreach ($GroupDN in $TargetGroups) {
    if ([string]::IsNullOrWhiteSpace($GroupDN)) { continue }
    
    Write-Host "Processing AD Security Group: $GroupDN"
    $Added = $false

    # 1. Primary Attempt using the active protocol (LDAPS:636 or LDAP:389)
    try {
        $GroupLdapPath    = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$GroupDN"
        $GroupObject      = New-Object System.DirectoryServices.DirectoryEntry($GroupLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
        $ComputerLdapPath = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$ComputerDN"

        # Invoke LDAP 'Add' method targeting the pinned DC
        $GroupObject.Invoke("Add", $ComputerLdapPath)
        $GroupObject.CommitChanges()

        Write-Host "Success: Added '$ComputerName' to group '$GroupDN' via $TargetDCHostname ($ActiveProtocol)." -ForegroundColor Green
        $Added = $true
    }
    catch {
        $ErrMessage = $_.Exception.Message
        
        # Check if already a member (HRESULT 0x80071392 / 'The object already exists')
        if ($ErrMessage -match "already exists|already a member" -or ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match "already exists|already a member")) {
            Write-Host "Notice: Computer '$ComputerName' is already a member of group '$GroupDN'." -ForegroundColor Yellow
            $Added = $true
        }
        else {
            # 2. IF LDAPS (Port 636) FAILED, FALL BACK TO STANDARD LDAP (Port 389)
            if ($ActiveLdapPort -eq 636 -and $AllowLdapFallback) {
                Write-Warning "LDAPS group addition failed for '$GroupDN' ($ErrMessage)."
                Write-Warning "Attempting immediate fallback to Standard LDAP (Port 389) with Kerberos/NTLM..."
                
                try {
                    $FallbackAuthType     = [System.DirectoryServices.AuthenticationTypes]::Secure
                    $GroupFallbackPath    = "LDAP://$($TargetDCHostname):389/$GroupDN"
                    $GroupFallbackObj     = New-Object System.DirectoryServices.DirectoryEntry($GroupFallbackPath, $PlainUser, $PlainPass, $FallbackAuthType)
                    $ComputerFallbackPath = "LDAP://$($TargetDCHostname):389/$ComputerDN"
                    
                    $GroupFallbackObj.Invoke("Add", $ComputerFallbackPath)
                    $GroupFallbackObj.CommitChanges()
                    
                    Write-Host "Success: Added '$ComputerName' to group '$GroupDN' via Standard LDAP (Port 389 Fallback)." -ForegroundColor Green
                    $Added = $true
                    
                    # Switch ActiveProtocol to port 389 for any remaining groups to prevent duplicate timeouts
                    $ActiveLdapPort = 389
                    $ActiveAuthType = $FallbackAuthType
                    $ActiveProtocol = "Standard LDAP (Port 389 - Fallback Active)"
                }
                catch {
                    $FallbackErrMsg = $_.Exception.Message
                    if ($FallbackErrMsg -match "already exists|already a member") {
                        Write-Host "Notice: Computer '$ComputerName' is already a member of group '$GroupDN'." -ForegroundColor Yellow
                        $Added = $true
                    } else {
                        Write-Error "Failed to add to group '$GroupDN' even after LDAP fallback. Error: $FallbackErrMsg"
                        if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
                    }
                }
            }
            else {
                Write-Error "Failed to add to group '$GroupDN'. Error: $ErrMessage"
                if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
            }
        }
    }
}

Write-Host "================================================================="
Write-Host "Domain Join and Active Directory Provisioning Completed Successfully."
Write-Host "================================================================="
