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
    [string]$TestLdapsServer = "",

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
# --- STEP 1.5 - BOOTSTRAP ENTERPRISE ROOT CA (Enables LDAPS on Workgroup Machines) ---
# ==============================================================================
# Fresh workgroup computers do not trust internal Active Directory Certificate Services (AD CS)
# certificates until joined to the domain. This causes Windows SChannel to abort the TLS handshake
# on port 636 with "The server is not operational" (SEC_E_UNTRUSTED_ROOT 0x80090325).
# Active Directory stores its Enterprise Root and Intermediate CAs in the Configuration partition.
# We read the CA certificate via Standard LDAP (Port 389) using the provided credentials
# and import it into Cert:LocalMachineRoot, allowing LDAPS (636) to establish a trusted TLS session.
Write-Host "Checking Active Directory Enterprise PKI trust for LDAPS TLS encryption..." -ForegroundColor Cyan
try {
    $ConfigDN = "CN=Configuration,$DomainDN"
    $PkiLdapPath = "LDAP://$TargetDCHostname/CN=Certification Authorities,CN=Public Key Services,CN=Services,$ConfigDN"
    $PkiEntry = New-Object System.DirectoryServices.DirectoryEntry($PkiLdapPath, $PlainUser, $PlainPass, [System.DirectoryServices.AuthenticationTypes]::Secure)
    $PkiSearcher = New-Object System.DirectoryServices.DirectorySearcher($PkiEntry)
    $PkiSearcher.Filter = "(objectClass=certificationAuthority)"
    $PkiSearcher.PropertiesToLoad.Add("cACertificate") | Out-Null
    $PkiSearcher.PropertiesToLoad.Add("cn") | Out-Null
    $PkiSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $CaObjects = $PkiSearcher.FindAll()

    if ($null -ne $CaObjects -and $CaObjects.Count -gt 0) {
        $RootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root, [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $RootStore.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)

        foreach ($CaObj in $CaObjects) {
            $CaName = $CaObj.Properties["cn"][0]
            if ($CaObj.Properties["cacertificate"].Count -gt 0) {
                $RawBytes = $CaObj.Properties["cacertificate"][0]
                $CaCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,$RawBytes)
                
                # Verify if already in store
                $Exists = $RootStore.Certificates | Where-Object { $_.Thumbprint -eq $CaCert.Thumbprint }
                if (-not $Exists) {
                    $RootStore.Add($CaCert)
                    Write-Host "Success - Imported Enterprise Root CA '$CaName' ($($CaCert.Thumbprint)) into Trusted Root Store." -ForegroundColor Green
                } else {
                    Write-Host "Enterprise Root CA '$CaName' is already trusted in Local Machine store." -ForegroundColor Gray
                }
            }
        }
        $RootStore.Close()
    }
}
catch {
    Write-Warning "Notice during Root CA bootstrap - $($_.Exception.Message)"
}


# ==============================================================================
# --- STEP 2 - ACTIVE LDAP PROTOCOL VALIDATION & PRE-JOIN ACCOUNT CLEANUP ---
# ==============================================================================
$ActiveLdapPort = 389
$ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
$ActiveProtocol = "Standard LDAP (Port 389)"

# Real active query validation to test TLS before any cleanup
if ($UseSecureLdap) {
    Write-Host "Validating Secure LDAP (LDAPS port $PreferredLdapPort) on $TargetDCHostname..." -ForegroundColor Cyan
    $LdapsVerified = $false

    # Attempt 1 - With ServerBind and SecureSocketsLayer
    try {
        $LdapsTestPath = ("LDAP://" + $TargetDCHostname + ":" + $PreferredLdapPort + "/" + $DomainDN)
        $LdapsAuthType = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer -bor [System.DirectoryServices.AuthenticationTypes]::ServerBind
        $TestEntry     = New-Object System.DirectoryServices.DirectoryEntry($LdapsTestPath, $PlainUser, $PlainPass, $LdapsAuthType)
        
        $TestSearcher             = New-Object System.DirectoryServices.DirectorySearcher($TestEntry)
        $TestSearcher.Filter      = "(objectClass=*)"
        $TestSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Base
        $TestSearcher.PageSize    = 1
        $null = $TestSearcher.FindOne()
        
        $ActiveLdapPort = $PreferredLdapPort
        $ActiveAuthType = $LdapsAuthType
        $ActiveProtocol = "Secure LDAP (LDAPS Port $PreferredLdapPort / TLS Encrypted)"
        Write-Host "Success - Verified LDAPS connection and TLS handshake with $TargetDCHostname." -ForegroundColor Green
        $LdapsVerified  = $true
    }
    catch {
        # Attempt 2 - With Secure and SecureSocketsLayer
        try {
            $LdapsAuthType2 = [System.DirectoryServices.AuthenticationTypes]::SecureSocketsLayer -bor [System.DirectoryServices.AuthenticationTypes]::Secure
            $TestEntry2     = New-Object System.DirectoryServices.DirectoryEntry($LdapsTestPath, $PlainUser, $PlainPass, $LdapsAuthType2)
            $TestSearcher2  = New-Object System.DirectoryServices.DirectorySearcher($TestEntry2)
            $TestSearcher2.Filter      = "(objectClass=*)"
            $TestSearcher2.SearchScope = [System.DirectoryServices.SearchScope]::Base
            $TestSearcher2.PageSize    = 1
            $null = $TestSearcher2.FindOne()
            
            $ActiveLdapPort = $PreferredLdapPort
            $ActiveAuthType = $LdapsAuthType2
            $ActiveProtocol = "Secure LDAP (LDAPS Port $PreferredLdapPort / TLS Encrypted)"
            Write-Host "Success - Verified LDAPS connection and TLS handshake with $TargetDCHostname (SecureSocketsLayer)." -ForegroundColor Green
            $LdapsVerified  = $true
        }
        catch {
            $LdapsVerified = $false
        }
    }

    if (-not $LdapsVerified) {
        Write-Warning "Secure LDAP (Port $PreferredLdapPort) TLS handshake could not validate the server certificate on this workgroup machine."
        Write-Host "Workgroup TLS Note - Fresh machines in WORKGROUP do not have internal AD CS PKI trust until domain joined." -ForegroundColor Gray
        if ($AllowLdapFallback) {
            Write-Host "AUTOMATIC FALLBACK - Switching to Standard LDAP (Port 389) with Kerberos/NTLM authentication..." -ForegroundColor Yellow
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

$CleanComputerName = $ComputerName.Trim()
Write-Host "Searching Active Directory for '$CleanComputerName' across $DomainDN using $ActiveProtocol..." -ForegroundColor Cyan

# Determine correct ADSI path (Never pass :389 to ADSI to allow native Kerberos/NTLM authentication)
$SearchLdapPath = if ($ActiveLdapPort -eq 636) { ("LDAP://" + $TargetDCHostname + ":636/" + $DomainDN) } else { ("LDAP://" + $TargetDCHostname + "/" + $DomainDN) }

$FoundComputers = @()
try {
    $SearchRoot           = New-Object System.DirectoryServices.DirectoryEntry($SearchLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
    $Searcher             = New-Object System.DirectoryServices.DirectorySearcher($SearchRoot)
    $Searcher.Filter      = '(&(objectClass=computer)(|(sAMAccountName=' + $CleanComputerName + '$)(cn=' + $CleanComputerName + ')(name=' + $CleanComputerName + ')))'
    $Searcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
    $Searcher.PageSize    = 100
    $Searcher.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
    $Searcher.PropertiesToLoad.AddRange(@("distinguishedName", "sAMAccountName", "cn", "name"))
    
    $SearchResults = $Searcher.FindAll()
    if ($null -ne $SearchResults) {
        $FoundComputers = @($SearchResults)
    }
}
catch {
    Write-Warning "Notice during AD computer search with $ActiveProtocol - $($_.Exception.Message)"
    # If search failed on port 636, immediately fall back to Standard LDAP (No port in ADsPath)
    if ($ActiveLdapPort -ne 389 -and $AllowLdapFallback) {
        Write-Warning "Falling back to Standard LDAP for computer search..."
        $ActiveLdapPort = 389
        $ActiveAuthType = [System.DirectoryServices.AuthenticationTypes]::Secure
        $ActiveProtocol = "Standard LDAP (Port 389 - Fallback Active)"
        try {
            # Note - Standard LDAP in ADSI must NEVER have :389 in the path
            $FallbackSearchPath = "LDAP://$TargetDCHostname/$DomainDN"
            $FallbackSearchRoot = New-Object System.DirectoryServices.DirectoryEntry($FallbackSearchPath, $PlainUser, $PlainPass, $ActiveAuthType)
            $FallbackSearcher   = New-Object System.DirectoryServices.DirectorySearcher($FallbackSearchRoot)
            $FallbackSearcher.Filter = '(&(objectClass=computer)(|(sAMAccountName=' + $CleanComputerName + '$)(cn=' + $CleanComputerName + ')(name=' + $CleanComputerName + ')))'
            $FallbackSearcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
            $FallbackSearcher.PageSize = 100
            $FallbackSearcher.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
            $FallbackSearcher.PropertiesToLoad.AddRange(@("distinguishedName", "sAMAccountName", "cn", "name"))
            
            $FallbackResults = $FallbackSearcher.FindAll()
            if ($null -ne $FallbackResults) {
                $FoundComputers = @($FallbackResults)
            }
            Write-Host "Success - Executed search via Standard LDAP." -ForegroundColor Green
        }
        catch {
            Write-Warning "Standard LDAP fallback search also reported - $($_.Exception.Message)"
        }
    }
}

# Delete stale computer object(s) if found
if ($FoundComputers.Count -gt 0) {
    Write-Warning "CONFLICT DETECTED - Found $($FoundComputers.Count) existing computer object(s) in Active Directory matching '$CleanComputerName'."
    
    foreach ($Result in $FoundComputers) {
        $ExistingDN = $Result.Properties["distinguishedname"][0]
        Write-Host "Processing stale computer account - $ExistingDN" -ForegroundColor Yellow
        
        $Deleted = $false
        try {
            $ComputerEntry = $Result.GetDirectoryEntry()
            $ComputerEntry.Username = $PlainUser
            $ComputerEntry.Password = $PlainPass
            $ComputerEntry.AuthenticationType = $ActiveAuthType

            # 1. Unprotect from accidental deletion if enabled in Active Directory
            try {
                $SecDescriptor = $ComputerEntry.ObjectSecurity
                $DenyRules = $SecDescriptor.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | 
                    Where-Object { $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny }
                
                if ($DenyRules) {
                    Write-Host "Removing accidental deletion protection from '$ExistingDN'..." -ForegroundColor Yellow
                    foreach ($Rule in $DenyRules) {
                        $SecDescriptor.RemoveAccessRule($Rule) | Out-Null
                    }
                    $ComputerEntry.ObjectSecurity = $SecDescriptor
                    $ComputerEntry.CommitChanges()
                    Write-Host "Accidental deletion protection removed." -ForegroundColor Green
                }
            }
            catch {
                # Non-fatal if account is not protected or lacks DACL permissions
            }

            # 2. Deletion Attempt A - Standard Active Directory Parent Container Removal
            try {
                $ParentDN = $ComputerEntry.Parent
                $ParentEntry = New-Object System.DirectoryServices.DirectoryEntry($ParentDN, $PlainUser, $PlainPass, $ActiveAuthType)
                $ParentEntry.Delete("computer", $ComputerEntry.Name)
                $ParentEntry.CommitChanges()
                Write-Host "Success - Deleted stale computer '$CleanComputerName' via Parent Container ($TargetDCHostname)." -ForegroundColor Green
                $Deleted = $true
            }
            catch {
                # Deletion Attempt B - DeleteTree (cleans up any child objects like BitLocker recovery keys)
                try {
                    $ComputerEntry.DeleteTree()
                    Write-Host "Success - Deleted stale computer '$CleanComputerName' via DeleteTree ($TargetDCHostname)." -ForegroundColor Green
                    $Deleted = $true
                }
                catch {
                    Write-Warning "Could not delete stale computer object '$ExistingDN' - $($_.Exception.Message)"
                }
            }
        }
        catch {
            Write-Warning "Error while processing stale computer account - $($_.Exception.Message)"
        }
    }

    Write-Host "Waiting 3 seconds for Active Directory deletion to commit..."
    Start-Sleep -Seconds 3

    # Verification Query - Confirm stale account is completely removed before joining
    try {
        $VerifyPath = if ($ActiveLdapPort -eq 636) { ("LDAP://" + $TargetDCHostname + ":636/" + $DomainDN) } else { ("LDAP://" + $TargetDCHostname + "/" + $DomainDN) }
        $VerifyRoot = New-Object System.DirectoryServices.DirectoryEntry($VerifyPath, $PlainUser, $PlainPass, $ActiveAuthType)
        $VerifySearcher = New-Object System.DirectoryServices.DirectorySearcher($VerifyRoot)
        $VerifySearcher.Filter = '(&(objectClass=computer)(sAMAccountName=' + $CleanComputerName + '$))'
        $VerifySearcher.SearchScope = [System.DirectoryServices.SearchScope]::Subtree
        $VerifyResult = $VerifySearcher.FindOne()
        if ($null -eq $VerifyResult) {
            Write-Host "Verified - Active Directory pre-join cleanup confirmed. Zero stale objects remain." -ForegroundColor Green
        } else {
            Write-Warning "Stale computer account still detected in AD after deletion attempt. Domain join may report a naming conflict."
        }
    }
    catch {
        # Non-fatal, continue to domain join
    }
}
else {
    Write-Host "No existing computer account found with name '$CleanComputerName' on $TargetDCHostname. Clean state confirmed. Proceeding to join." -ForegroundColor Green
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
        $GroupLdapPath = if ($ActiveLdapPort -eq 636) { ("LDAP://" + $TargetDCHostname + ":636/" + $GroupDN) } else { ("LDAP://" + $TargetDCHostname + "/" + $GroupDN) }
        $GroupObject   = New-Object System.DirectoryServices.DirectoryEntry($GroupLdapPath, $PlainUser, $PlainPass, $ActiveAuthType)
        
        # Test directory binding by checking Guid before invoking
        $null = $GroupObject.Guid

        $ComputerLdapPath = if ($ActiveLdapPort -eq 636) { ("LDAP://" + $TargetDCHostname + ":636/" + $ComputerDN) } else { ("LDAP://" + $TargetDCHostname + "/" + $ComputerDN) }
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
            # 2. IMMEDIATE FALLBACK TO STANDARD LDAP (Port 389 without explicit port in ADsPath)
            if ($AllowLdapFallback) {
                Write-Warning "Group addition failed with $ActiveProtocol - $ErrMessage"
                Write-Warning "Attempting immediate fallback to Standard LDAP with Kerberos/NTLM..."
                
                try {
                    $FallbackAuthType  = [System.DirectoryServices.AuthenticationTypes]::Secure
                    $GroupFallbackPath = "LDAP://$TargetDCHostname/$GroupDN"
                    $GroupFallbackObj  = New-Object System.DirectoryServices.DirectoryEntry($GroupFallbackPath, $PlainUser, $PlainPass, $FallbackAuthType)
                    
                    # Force bind
                    $null = $GroupFallbackObj.Guid
                    
                    # Try with DC path, then fallback to relative DN
                    try {
                        $GroupFallbackObj.Invoke("Add", "LDAP://$TargetDCHostname/$ComputerDN")
                    }
                    catch {
                        $GroupFallbackObj.Invoke("Add", "LDAP://$ComputerDN")
                    }
                    $GroupFallbackObj.CommitChanges()
                    
                    Write-Host "Success - Added '$ComputerName' to group '$GroupDN' via Standard LDAP (Fallback Active)." -ForegroundColor Green
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
