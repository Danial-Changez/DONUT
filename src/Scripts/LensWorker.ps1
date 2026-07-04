#Requires -Version 5.1
<#
.SYNOPSIS
    De-elevated inner worker for the user Lens: resolves a person to their directory
    facts + SCCM devices + BitLocker keys, and writes the bundle as JSON.

.DESCRIPTION
    Runs as the INTERACTIVE (regular) user - launched by LensLookupWorker via a
    de-elevated scheduled task - because SCCM (AdminService) and BitLocker (AD) are
    readable only by that account, while DONUT itself runs elevated as the admin
    account. The pipeline (validated in tools/Get-PersonLens.ps1):
      1. AD user, forest-wide via the Global Catalog then home-domain bind:
         UPN / SAM / displayName / mail / manager / office.
      2. SCCM affinity: endswith(UniqueUserName,'<SAM>') -> WSID(s) (exact-tail filtered).
      3. Per WSID: model + last hardware-sync (SCCM), BitLocker keys (AD msFVE-* children,
         home domain located via the GC).
    The bundle is written to -ResultPath as JSON matching the PersonLens DTO shape.

.PARAMETER Identity
    UPN / DOMAIN\SAM / bare SAM / display name to resolve.

.PARAMETER SiteServer
    SCCM AdminService host (e.g. sccm01.contoso.com).

.PARAMETER ResultPath
    File to write the JSON bundle to (read back by LensLookupWorker over the exchange dir).

.NOTES
    Read-only against AD/SCCM. Uses raw LDAP/DirectorySearcher (no AD module) + the
    AdminService REST endpoint (no ConfigMgr module / PSDrive).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Identity,
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $ResultPath
)

$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-Cn([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

$forestNc = [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0]
function Find-Gc([string]$Filter) {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.SearchRoot = [ADSI]"GC://$forestNc"
    $s.Filter = $Filter
    $s.PageSize = 200
    [void]$s.PropertiesToLoad.Add('distinguishedName')
    return $s.FindOne()
}

# AdminService /wmi query as the current (regular) user. ${Class} MUST be braced:
# '?' is a valid variable-name char, so "$Class?" would drop the class from the URL.
function Get-Sccm([string]$Class, [string]$Filter, [string]$Select) {
    $rel = "wmi/${Class}?`$filter=" + [uri]::EscapeDataString($Filter) + $(if ($Select) { "&`$select=$Select" } else { '' })
    $p = @{ Uri = "https://$SiteServer/AdminService/$rel"; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

$bundle = [ordered]@{
    upn = ''; sam = ''; displayName = ''; email = ''; manager = ''; office = ''
    devices = @(); errors = @()
}

# --- AD user (forest-wide GC -> home-domain bind) ---------------------------------
$sam = if ($Identity -match '\\') { $Identity.Split('\')[-1] } else { $Identity }
$uFilter =
    if ($Identity -match '@') { "(&(objectClass=user)(userPrincipalName=$Identity))" }
    elseif ($Identity -match '\s') { "(&(objectClass=user)(displayName=$Identity))" }
    else { "(&(objectClass=user)(sAMAccountName=$sam))" }
try {
    $uHit = Find-Gc $uFilter
    if (-not $uHit) { throw "no AD user matched '$Identity'." }
    $user = [ADSI]"LDAP://$([string]$uHit.Properties['distinguishedname'][0])"   # binds home domain
    $bundle.sam         = [string]$user.Properties['samaccountname'][0]
    $bundle.displayName = [string]$user.Properties['displayname'][0]
    $bundle.upn         = [string]$user.Properties['userprincipalname'][0]
    $bundle.email       = [string]$user.Properties['mail'][0]
    $mgrDn = [string]$user.Properties['manager'][0]
    if ($mgrDn) { $bundle.manager = Get-Cn $mgrDn }
    $office = @()
    foreach ($k in 'physicaldeliveryofficename', 'streetaddress', 'l', 'st', 'postalcode') {
        $v = [string]$user.Properties[$k][0]; if ($v) { $office += $v }
    }
    $bundle.office = ($office -join ', ')
    if ($bundle.sam) { $sam = $bundle.sam }
}
catch {
    $bundle.errors += "AD user: $($_.Exception.Message)"
}

# --- SCCM user -> WSID(s) ---------------------------------------------------------
$wsids = @()
if ($sam) {
    try {
        $rows = Get-Sccm 'SMS_UserMachineRelationship' "endswith(UniqueUserName,'$sam')" 'UniqueUserName,ResourceName'
        $wsids = @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
    }
    catch {
        $bundle.errors += "SCCM affinity: $($_.Exception.Message)"
    }
}

# --- Per WSID: model + last-sync (SCCM) and BitLocker (AD) -------------------------
$devices = [System.Collections.Generic.List[object]]::new()
foreach ($wsid in $wsids) {
    $dev = [ordered]@{ name = $wsid; model = ''; lastSync = ''; domain = ''; note = ''; bitLockerKeys = @() }

    # SCCM ResourceID (Name eq - no backslash), then model + last hardware-sync.
    try {
        $sys = Get-Sccm 'SMS_R_System' "Name eq '$wsid'" 'ResourceID,Name'
        $rid = if ($sys -and $sys.Count -gt 0) { $sys[0].ResourceID } else { $null }
        if ($rid) {
            $cs = Get-Sccm 'SMS_G_System_COMPUTER_SYSTEM' "ResourceID eq $rid" 'Model'
            if ($cs -and $cs.Count -gt 0) { $dev.model = [string]$cs[0].Model }
            $ws = Get-Sccm 'SMS_G_System_WORKSTATION_STATUS' "ResourceID eq $rid" 'LastHWScan'
            if ($ws -and $ws.Count -gt 0) { $dev.lastSync = [string]$ws[0].LastHWScan }
        }
    }
    catch {
        $dev.note = "SCCM device detail: $($_.Exception.Message)"
    }

    # BitLocker (AD): GC-locate the computer forest-wide, bind its home domain, read the
    # msFVE-RecoveryInformation children.
    try {
        $cHit = Find-Gc "(&(objectClass=computer)(cn=$wsid))"
        if ($cHit) {
            $compDn = [string]$cHit.Properties['distinguishedname'][0]
            $dev.domain = (($compDn -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')
            $bl = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
            $bl.Filter = '(objectClass=msFVE-RecoveryInformation)'
            'msfve-recoverypassword', 'whencreated' | ForEach-Object { [void]$bl.PropertiesToLoad.Add($_) }
            $keys = @($bl.FindAll())
            if ($keys.Count -gt 0) {
                $dev.bitLockerKeys = @($keys | ForEach-Object {
                        @{ password = [string]$_.Properties['msfve-recoverypassword'][0]; created = [string]$_.Properties['whencreated'][0] }
                    })
            }
            elseif (-not $dev.note) { $dev.note = 'BitLocker not escrowed to AD (or not readable)' }
        }
        elseif (-not $dev.note) { $dev.note = 'computer object not found in AD' }
    }
    catch {
        if (-not $dev.note) { $dev.note = "BitLocker: $($_.Exception.Message)" }
    }

    $devices.Add($dev)
}
$bundle.devices = $devices.ToArray()

# --- Emit --------------------------------------------------------------------------
try {
    $bundle | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
}
catch {
    # Last resort: write a minimal error bundle so the caller never hangs on a missing file.
    (@{ errors = @("LensWorker could not write the result: $($_.Exception.Message)") } | ConvertTo-Json) |
        Set-Content -LiteralPath $ResultPath -Encoding UTF8 -ErrorAction SilentlyContinue
}
