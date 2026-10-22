<#
.SYNOPSIS
    Automated Active Directory Domain Join & Group Assignment for Turner Industries.
.DESCRIPTION
    Joins target machine(s) to domain "turner-industries.com" in OU "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"
    and automatically assigns computer object membership to:
    - CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com
.NOTES
    Domain: turner-industries.com
    Target OU: OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com
    Generated: 2026-10-19
    Log Path: C:\Windows\debug\NetSetup.LOG
#>

[CmdletBinding()]
param()

# Strict error mode
$ErrorActionPreference = "Stop"

# -------------------------------------------------------------------------
# 1. Verify Local Administrator Elevation
# -------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Error "This script must be executed in an elevated PowerShell session (Run as Administrator)." -ErrorAction Stop
}
Write-Host "[OK] Elevated Administrator token verified." -ForegroundColor Green

# -------------------------------------------------------------------------
# 2. Start Transcript Logging
# -------------------------------------------------------------------------
$LogDir = "C:\ProgramData\TurnerIndustries\Logs"
if (-not (Test-Path -Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ("DomainJoin_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
Start-Transcript -Path $LogFile -Append
Write-Host "[LOG] Session transcript active at $LogFile" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# 3. Pre-Flight Connectivity & DNS Verification
# -------------------------------------------------------------------------
$Domain = "turner-industries.com"
Write-Host "[CHECK] Resolving Active Directory domain DNS..." -NoNewline
try {
    $dnsResult = Resolve-DnsName -Name $Domain -Type A -ErrorAction Stop
    Write-Host " [PASSED]" -ForegroundColor Green
    Write-Host "        Domain Controller IPs: $($dnsResult.IPAddress -join ', ')" -ForegroundColor Gray
} catch {
    Write-Host " [FAILED]" -ForegroundColor Red
    Write-Error "Unable to resolve $Domain. Check IPv4 DNS settings on your network adapter." -ErrorAction Stop
}

Write-Host "[CHECK] Testing LDAP service connectivity (Port 389)..." -NoNewline
try {
    $tcpTest = Test-NetConnection -ComputerName $Domain -Port 389 -WarningAction SilentlyContinue
    if ($tcpTest.TcpTestSucceeded) {
        Write-Host " [PASSED]" -ForegroundColor Green
    } else {
        Write-Host " [FAILED]" -ForegroundColor Yellow
        Write-Warning "TCP 389 unreachable. Check VPN, firewall or routing to Turner domain controllers."
    }
} catch {
    Write-Warning "Unable to run Test-NetConnection; continuing..."
}

# -------------------------------------------------------------------------
# 4. Active Directory Credential Acquisition
# -------------------------------------------------------------------------
Write-Host "Enter your Turner Industries domain credentials (e.g. turner-industries\username):" -ForegroundColor Cyan
$Credential = Get-Credential -UserName "turner-industries\" -Message "Enter credentials authorized to join OU and assign groups"

# -------------------------------------------------------------------------
# 5. Configuration Parameters
# -------------------------------------------------------------------------
$TargetDomain = "turner-industries.com"
$TargetOU     = "OU=Baton Rouge,OU=All_Computers,DC=turner-industries,DC=com"

# -------------------------------------------------------------------------
# 6. Join Local Computer to Turner Industries Domain
# -------------------------------------------------------------------------
try {
    $currentComp = Get-CimInstance -ClassName Win32_ComputerSystem
    if ($currentComp.PartOfDomain) {
        Write-Host "[INFO] Computer is already joined to domain: $($currentComp.Domain)" -ForegroundColor Yellow
    }

    Write-Host "[JOIN] Initiating domain join to '$TargetDomain' into OU:" -ForegroundColor Cyan
    Write-Host "       $TargetOU" -ForegroundColor Gray

    # Execute Add-Computer cmdlet
    Add-Computer -DomainName $TargetDomain `
                 -OUPath $TargetOU `
                 -Credential $Credential `
                 -Force -ErrorAction Stop

    Write-Host "[SUCCESS] Successfully joined to $TargetDomain in target OU!" -ForegroundColor Green

    # -------------------------------------------------------------------------
    # 7. Add Computer Object to Active Directory Security Group(s)
    # -------------------------------------------------------------------------
    $TargetMachineName = $env:COMPUTERNAME
    $ComputerDN = "CN=$TargetMachineName,$TargetOU"
    $ComputerSAM = "$($TargetMachineName)$"

    $GroupsToAdd = @(
        "CN=Grp_ClientComputerCert,OU=Helpdesk ModifyGroups,DC=turner-industries,DC=com"
    )

    Write-Host "[GROUP] Assigning computer to security groups..." -ForegroundColor Cyan
    foreach ($grpDN in $GroupsToAdd) {
        Write-Host "        -> Target Group: $grpDN" -ForegroundColor Gray
        try {
            # Auto method: Uses ActiveDirectory module if installed, or native ADSI if not
            if (Get-Module -ListAvailable -Name ActiveDirectory) {
                Import-Module ActiveDirectory -ErrorAction SilentlyContinue
                Add-ADGroupMember -Identity $grpDN -Members $ComputerSAM -Credential $Credential -ErrorAction Stop
                Write-Host "           [OK] Added via ActiveDirectory module" -ForegroundColor Green
            } else {
                $domainUser = $Credential.UserName
                $plainPass  = $Credential.GetNetworkCredential().Password
                $groupEntry = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$grpDN", $domainUser, $plainPass)
                $groupEntry.Properties["member"].Add($ComputerDN) | Out-Null
                $groupEntry.CommitChanges()
                Write-Host "           [OK] Added via native ADSI LDAP provider" -ForegroundColor Green
            }
        } catch {
            if ($_.Exception.Message -match "already exists|member already") {
                Write-Host "           [INFO] Computer is already a member of this group." -ForegroundColor Yellow
            } else {
                Write-Host "           [WARN] Group assignment error: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "[REBOOT] System will reboot in 15 seconds to complete registration..." -ForegroundColor Yellow
    Restart-Computer -Force -Timeout 15
} catch {
    Write-Host "[ERROR] Operation failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "[DEBUG] Refer to detailed NetJoin log at C:\Windows\debug\NetSetup.LOG" -ForegroundColor Yellow
    throw $_
}

# -------------------------------------------------------------------------
# 8. Post-Join Validation
# -------------------------------------------------------------------------
Write-Host "[VERIFY] Checking secure channel trust relationship..." -ForegroundColor Cyan
try {
    $channelStatus = Test-ComputerSecureChannel -Verbose
    if ($channelStatus) {
        Write-Host "[OK] Secure channel with Turner Industries domain is healthy." -ForegroundColor Green
    } else {
        Write-Host "[WARN] Secure channel test returned false. Reboot will establish trust." -ForegroundColor Yellow
    }
} catch {
    Write-Host "[INFO] Secure channel will establish upon system reboot." -ForegroundColor Gray
}

# -------------------------------------------------------------------------
# ROLLBACK / DISJOIN PROCEDURE (IF NEEDED)
# -------------------------------------------------------------------------
# To remove this computer from the domain and return to WORKGROUP:
# Remove-Computer -UnjoinDomainCredential (Get-Credential) -WorkgroupName "WORKGROUP" -Restart -Force

Stop-Transcript
