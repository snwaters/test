<#
================================================================================
.SYNOPSIS
    Automated Active Directory Domain Join with Pre-Flight Domain Membership Check,
    FQDN Normalization, Active LDAPS Query Validation, Automatic Standard LDAP Fallback,
    Pre-Join Account Cleanup, and Resilient Security Group Provisioning.

.DESCRIPTION
    0. PRE-FLIGHT CHECK: Checks if the local machine is already joined to the
       target domain (via Win32_ComputerSystem CIM). Prevents redundant executions
       and protects against self-destructive AD account deletion.
    1. DC DISCOVERY & FQDN NORMALIZATION:
       - Discovers or tests specific DC, ensuring short NetBIOS names (e.g. dfw1-dc1)
         are expanded to FQDN (dfw1-dc1.turner-industries.com) to prevent SSL certificate
         SAN mismatch errors ("The server is not operational").
    2. PROTOCOL SELECTION & RESILIENT BINDING:
       - Performs an ACTIVE query test (DirectorySearcher) to verify genuine TLS capability.
       - If LDAPS fails (untrusted CA, missing cert, or port blocked), automatically
         and immediately falls back to Standard LDAP (Port 389) for both Step 2 and Step 4.
    3. Searches Active Directory for any pre-existing/stale computer account
       matching the current hostname and deletes it (.NET ADSI) to eliminate
       "Account already exists", duplicate SPN, or "Access denied" join conflicts.
    4. Joins the domain into the target OU targeting the pinned DC.
    5. AD SECURITY GROUPS WITH PER-GROUP LDAP FALLBACK:
       - Adds computer to designated security groups with instant port 389 fallback
         and duplicate membership handling.
================================================================================
#>

[CmdletBinding()]
param(
    # Optional field to test a specific LDAPS server (hostname, FQDN, or host:port).
    # If left blank, the script proceeds as usual with dynamic DC discovery.
    [string]$TestLdapsServer = "dfw1-dc1",

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
$AllowLdapFallback  = $false # Fall back to port 389 if LDAPS fails

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
    Write-Host "Current Status - Computer is joined to domain '$CurrentDomain'." -ForegroundColor Yellow
    
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
            Write-Warning "Could not verify secure channel - $_"
        }

        if ($ForceRejoin) {
            Write-Warning "ForceRejoin switch specified. Proceeding with clean re-join process..."
        } else {
            Write-Host "=================================================================" -ForegroundColor Green
            Write-Host "SUCCESS - Machine is already a member of '$Domain'. No action needed." -ForegroundColor Green
            Write-Host "Exiting cleanly (Exit Code 0). Safe from redundant join or AD deletion." -ForegroundColor Green
            Write-Host "=================================================================" -ForegroundColor Green
            exit 0
        }
    }
    else {
        # Joined to a DIFFERENT domain
        Write-Warning "CONFLICT - Computer is currently joined to a different domain - '$CurrentDomain' (Target is '$Domain')."
        if (-not $ForceRejoin) {
            Write-Error "Halting. To disjoin from '$CurrentDomain' and rejoin '$Domain', re-run with -ForceRejoin or disjoin manually."
            exit 2
        }
        Write-Warning "ForceRejoin switch active - Will attempt migration from '$CurrentDomain' to '$Domain'."
    }
}
else {
    $Workgroup = if ($CurrentSystem.Workgroup) { $CurrentSystem.Workgroup } else { "WORKGROUP" }
    Write-Host "Confirmed - Computer is in workgroup '$Workgroup' (Not joined to any domain)." -ForegroundColor Green
    Write-Host "Proceeding with automated domain join to '$Domain'..." -ForegroundColor Cyan
}

# ==============================================================================
# --- STEP 1: DC DISCOVERY, FQDN NORMALIZATION & LDAPS SERVER TEST ---
# ==============================================================================
$TargetDCHostname = $null
$DomainDN         = (($Domain.Split('.') | ForEach-Object { "DC=$_" }) -join ',')
$PlainUser        = $Cred.UserName
$PlainPass        = $Cred.GetNetworkCredential().Password

# Check if the user specified a custom LDAPS test server in $TestLdapsServer
if (-not [string]::IsNullOrWhiteSpace($TestLdapsServer)) {
    Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
    Write-Host "Specific LDAPS test server configured - '$TestLdapsServer'" -ForegroundColor Cyan

    $ServerHost = $TestLdapsServer.Split(':')[0].Trim()
    $ServerPort = if ($TestLdapsServer.Contains(':')) { [int]$TestLdapsServer.Split(':')[1] } else { $PreferredLdapPort }

    # Ensure FQDN to prevent SSL Subject Name mismatch
    if ($ServerHost -notlike "*.*") {
        $ServerHost = "$ServerHost.$Domain"
    }

    Write-Host "Testing TCP Port $ServerPort on '$ServerHost'..." -ForegroundColor Gray
    $TcpResult = Test-NetConnection -ComputerName $ServerHost -Port $ServerPort -WarningAction SilentlyContinue

    if ($TcpResult.TcpTestSucceeded) {
        Write-Host "TCP Port $ServerPort is OPEN on '$ServerHost'." -ForegroundColor Green
        $TargetDCHostname = $ServerHost
    }
    else {
        Write-Warning "TCP test to '$ServerHost' on port $ServerPort FAILED. Falling back to dynamic DNS discovery as usual..."
    }
    Write-Host "-----------------------------------------------------------------" -ForegroundColor Cyan
}

# If $TestLdapsServer was blank (or failed reachability), proceed with dynamic DNS discovery as usual
if ([string]::IsNullOrEmpty($TargetDCHostname)) {
    if ([string]::IsNullOrWhiteSpace($TestLdapsServer)) {
        Write-Host "Notice - TestLdapsServer field is blank. Proceeding with dynamic DNS discovery as usual..." -ForegroundColor Gray
    }
    Write-Host "Locating Domain Controller for $Domain via DNS with retries..." -ForegroundColor Cyan
    $Attempt = 0
    $MaxAttempts = 15

    while ($null -eq $TargetDCHostname -and $Attempt -lt $MaxAttempts) {
        $Attempt++
        try {
            $DomainDNS   = [System.Net.Dns]::GetHostEntry($Domain)
            $BestDCIP    = $DomainDNS.AddressList[0].IPAddressToString
            $DCHostEntry = [System.Net.Dns]::GetHostEntry($BestDCIP)
            $TargetDCHostname = $DCHostEntry.HostName

            Write-Host "Success! Located Domain Controller $TargetDCHostname ($BestDCIP)"
        }
        catch {
            Write-Warning "Attempt $($Attempt) of $($MaxAttempts) - DNS not ready yet. Waiting 3s..."
            Start-Sleep -Seconds 3
        }
    }
}

# --- CRITICAL FIX 1: FQDN EXPANSION (Resolves dfw1-dc1 -> dfw1-dc1.turner-industries.com) ---
if ($TargetDCHostname -notlike "*.*" -and -not [string]::IsNullOrEmpty($TargetDCHostname)) {
    $TargetDCHostname = "$TargetDCHostname.$Domain"
    Write-Host "Expanded DC Hostname to FQDN for LDAPS certificate validation - $TargetDCHostname" -ForegroundColor Cyan
}

# --- SAFETY CHECK ---
if ([string]::IsNullOrEmpty($TargetDCHostname)) {
    Write-Error "CRITICAL FAILURE - Could not resolve a Domain Controller after $MaxAttempts attempts."
    Write-Error "Verify network link, DHCP lease, and DNS server configuration."
    exit 1
}

# ==============================================================================
# --- STEP 2: ACTIVE LDAP PROTOCOL VALIDATION & PRE-JOIN ACCOUNT CLEANUP ---
# ==============================================================================
$ActiveLdapPort = 389
$ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
$ActiveProtocol = "Standard LDAP (Port 389)"

# --- CRITICAL FIX 2: REAL ACTIVE QUERY VALIDATION ---
# Executes an actual DirectorySearcher query to test TLS before any cleanups
if ($UseSecureLdap) {
    Write-Host "Validating Secure LDAP (LDAPS port $PreferredLdapPort) on $TargetDCHostname..." -ForegroundColor Cyan
    try {
        $LdapsTestPath = "LDAP://$($TargetDCHostname):$PreferredLdapPort/$DomainDN"
        $LdapsAuthType = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer -bor [System.DirectoryServices.AuthenticationTypes]::Secure
        $TestEntry     = New-Object System.DirectoryServices.DirectoryEntry($LdapsTestPath, $PlainUser, $PlainPass, $LdapsAuthType)
        
        # Dispatch live query across the TLS socket
        $TestSearcher             = New-Object System.DirectoryServices.DirectorySearcher($TestEntry)
        $TestSearcher.Filter      = "(objectClass=*)"
        $TestSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Base
        $TestSearcher.PageSize    = 1
        $null = $TestSearcher.FindOne()
        
        $ActiveLdapPort = $PreferredLdapPort
        $ActiveAuthType = $LdapsAuthType
        $ActiveProtocol = "Secure LDAP (LDAPS Port $PreferredLdapPort / TLS Encrypted)"
        Write-Host "Success - Verified LDAPS connection and TLS handshake with $TargetDCHostname." -ForegroundColor Green
    }
    catch {
        Write-Warning "Secure LDAP (Port $PreferredLdapPort) test failed on $TargetDCHostname - $($_.Exception.Message)"
        if ($AllowLdapFallback) {
            Write-Warning "AUTOMATIC FALLBACK - Switching to Standard LDAP (Port 389) with Kerberos/NTLM authentication..."
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

# Search & Cleanup with in-line fallback
$ExistingComputerResult = $null
try {
    $SearchLdapPath = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$DomainDN"
    $SearchRoot     = New-Object System.DirectoryServices.DirectoryEntry($SearchLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
    $Searcher       = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $Searcher.Filter      = '(&(objectCategory=computer)(sAMAccountName=' + $ComputerName + '$))'
    $Searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $Searcher.PageSize    = 10
    $ExistingComputerResult = $Searcher.FindOne()
}
catch {
    Write-Warning "Notice during AD computer cleanup with $ActiveProtocol - $($_.Exception.Message)"
    # If search failed on port 636, immediately fall back to port 389
    if ($ActiveLdapPort -ne 389 -and $AllowLdapFallback) {
        Write-Warning "Falling back to Standard LDAP (Port 389) for computer search..."
        $ActiveLdapPort = 389
        $ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
        $ActiveProtocol = "Standard LDAP (Port 389 - Fallback Active)"
        try {
            $FallbackSearchPath = "LDAP://$($TargetDCHostname):389/$DomainDN"
            $FallbackSearchRoot = New-Object System.DirectoryServices.DirectoryEntry($FallbackSearchPath, $PlainUser, $PlainPass, $ActiveAuthType)
            $FallbackSearcher   = New-Object System.DirectoryServices.DirectorySearcher($FallbackSearchRoot)
            $FallbackSearcher.Filter = '(&(objectCategory=computer)(sAMAccountName=' + $ComputerName + '$))'
            $FallbackSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
            $ExistingComputerResult = $FallbackSearcher.FindOne()
            Write-Host "Success - Recovered and executed search via Standard LDAP (Port 389)." -ForegroundColor Green
        }
        catch {
            Write-Warning "Standard LDAP fallback search also reported - $($_.Exception.Message)"
        }
    }
}

# Delete stale computer object if found
if ($null -ne $ExistingComputerResult) {
    try {
        $ExistingDN = $ExistingComputerResult.Properties["distinguishedname"][0]
        Write-Warning "CONFLICT DETECTED - Found existing computer object in AD - $ExistingDN"
        Write-Host "Deleting stale computer object from $TargetDCHostname via $ActiveProtocol before joining..." -ForegroundColor Yellow
        
        $ComputerEntry = $ExistingComputerResult.GetDirectoryEntry()
        $ComputerEntry.Username = $PlainUser
        $ComputerEntry.Password = $PlainPass
        $ComputerEntry.AuthenticationType = $ActiveAuthType
        $ComputerEntry.DeleteTree()
        
        Write-Host "Success - Stale computer account deleted from Active Directory ($TargetDCHostname)." -ForegroundColor Green
        Write-Host "Waiting 3s for directory commit to settle..."
        Start-Sleep -Seconds 3
    }
    catch {
        Write-Warning "Could not delete stale computer object - $($_.Exception.Message)"
    }
} else {
    Write-Host "No existing computer account found with name '$ComputerName'. Clean state confirmed. Proceeding to join."
}

# --- STEP 3: JOIN DOMAIN (Targeting the Pinned DC) ---
Write-Host "Joining Domain '$Domain' into '$TargetOU' using $TargetDCHostname..."
try {
    Add-Computer -DomainName $Domain -Credential $Cred -OUPath $TargetOU -Server $TargetDCHostname -ErrorAction Stop
    Write-Host "Success - Computer '$ComputerName' successfully joined to domain '$Domain'." -ForegroundColor Green
}
catch {
    Write-Error "Join failed - $_"
    exit 1
}

# ==============================================================================
# --- STEP 4: ADD TO AD SECURITY GROUPS (Resilient with Port 389 Fallback) ---
# ==============================================================================
Write-Host "Assigning Computer to AD Groups on $TargetDCHostname via $ActiveProtocol..." -ForegroundColor Cyan

$ComputerDN = "CN=$ComputerName,$TargetOU"

foreach ($GroupDN in $TargetGroups) {
    if ([string]::IsNullOrWhiteSpace($GroupDN)) { continue }
    
    Write-Host "Processing AD Security Group $GroupDN"
    $Added = $false

    # 1. Primary Attempt using the active protocol
    try {
        $GroupLdapPath = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$GroupDN"
        $GroupObject   = New-Object System.DirectoryServices.DirectoryEntry($GroupLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
        
        # Test directory binding by checking Guid before invoking
        $null = $GroupObject.Guid

        $ComputerLdapPath = "LDAP://$($TargetDCHostname):$ActiveLdapPort/$ComputerDN"
        $GroupObject.Invoke("Add", $ComputerLdapPath)
        $GroupObject.CommitChanges()

        Write-Host "Success - Added '$ComputerName' to group '$GroupDN' via $TargetDCHostname ($ActiveProtocol)." -ForegroundColor Green
        $Added = $true
    }
    catch {
        $ErrMessage = $_.Exception.Message
        
        # Check if already a member (HRESULT 0x80071392 / 'The object already exists')
        if ($ErrMessage -match "already exists|already a member" -or ($_.Exception.InnerException -and $_.Exception.InnerException.Message -match "already exists|already a member")) {
            Write-Host "Notice - Computer '$ComputerName' is already a member of group '$GroupDN'." -ForegroundColor Yellow
            $Added = $true
        }
        else {
            # 2. IMMEDIATE FALLBACK TO STANDARD LDAP (Port 389)
            if ($AllowLdapFallback) {
                Write-Warning "Group addition failed with $ActiveProtocol - $ErrMessage"
                Write-Warning "Attempting immediate fallback to Standard LDAP (Port 389) with Kerberos/NTLM..."
                
                try {
                    $FallbackAuthType  = [System.DirectoryServices.AuthenticationTypes]::Secure
                    $GroupFallbackPath = "LDAP://$($TargetDCHostname):389/$GroupDN"
                    $GroupFallbackObj  = New-Object System.DirectoryServices.DirectoryEntry($GroupFallbackPath, $PlainUser, $PlainPass, $FallbackAuthType)
                    
                    # Force bind
                    $null = $GroupFallbackObj.Guid
                    
                    # Try with DC port 389 path, then fallback to relative DN
                    try {
                        $GroupFallbackObj.Invoke("Add", "LDAP://$($TargetDCHostname):389/$ComputerDN")
                    }
                    catch {
                        $GroupFallbackObj.Invoke("Add", "LDAP://$ComputerDN")
                    }
                    $GroupFallbackObj.CommitChanges()
                    
                    Write-Host "Success - Added '$ComputerName' to group '$GroupDN' via Standard LDAP (Port 389 Fallback)." -ForegroundColor Green
                    $Added = $true
                    
                    # Permanently switch active port to 389 so remaining groups succeed instantly
                    $ActiveLdapPort = 389
                    $ActiveAuthType = $FallbackAuthType
                    $ActiveProtocol = "Standard LDAP (Port 389 - Fallback Active)"
                }
                catch {
                    $FallbackErrMsg = $_.Exception.Message
                    if ($FallbackErrMsg -match "already exists|already a member") {
                        Write-Host "Notice - Computer '$ComputerName' is already a member of group '$GroupDN'." -ForegroundColor Yellow
                        $Added = $true
                    } else {
                        Write-Error "Failed to add to group '$GroupDN' on both LDAPS and LDAP fallback - $FallbackErrMsg"
                        if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
                    }
                }
            }
            else {
                Write-Error "Failed to add to group '$GroupDN' - $ErrMessage"
                if ($_.Exception.InnerException) { Write-Error $_.Exception.InnerException.Message }
            }
        }
    }
}

Write-Host "================================================================="
Write-Host "Domain Join and Active Directory Provisioning Completed Successfully."
Write-Host "================================================================="
