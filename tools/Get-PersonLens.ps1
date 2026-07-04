#Requires -Version 5.1
<#
.SYNOPSIS
    The Lens lookup: given a person (UPN / DOMAIN\SAM / SAM / display name), return
    manager, office, their WSID(s), and per-WSID BitLocker keys - all as your regular
    user, from each field's fastest source. This is the exact pipeline DONUT's
    de-elevated helper will run.

.DESCRIPTION
    Step 1  AD user (one Global Catalog search, forest-wide -> binds the home domain):
            sAMAccountName, msDS-PrincipalName (DOMAIN\SAM), manager, office.
    Step 2  SCCM AdminService: endswith(UniqueUserName,'<SAM>') -> WSID(s), client-
            filtered to the exact SAM tail.
    Step 3  Per WSID: GC-locate the computer forest-wide, bind its home domain, read
            the msFVE-RecoveryInformation children (BitLocker recovery passwords).

    SiteID and serial are intentionally omitted (present as fields but not populated
    in this environment). Read-only.

.PARAMETER Identity
    UPN ('asmith@contoso.com'), DOMAIN\SAM ('PRODUCTION\U0073097'), bare SAM
    ('U0073097'), or display name ('Danial Changez').

.PARAMETER SiteServer
    AdminService host. Default 'sccm01.contoso.com'.

.PARAMETER AsJson
    Emit the bundle as JSON (the shape the helper will hand back to DONUT) instead of
    the readable card.

.NOTES
    Run as your REGULAR user (AD across the 4 domains + SCCM + BitLocker read). Uses raw
    LDAP/DirectorySearcher (no AD module dependency), matching DONUT's ActiveDirectoryService.

.EXAMPLE
    pwsh -File tools\Get-PersonLens.ps1 -Identity 'PRODUCTION\U0073097'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Identity,
    [string] $SiteServer = 'sccm01.contoso.com',
    [switch] $AsJson
)

$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-Cn([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

# Forest-wide (Global Catalog) search: finds an object in ANY of the domains at once.
$forestNc = [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0]
function Find-GC([string]$Filter) {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.SearchRoot = [ADSI]"GC://$forestNc"
    $s.Filter = $Filter
    $s.PageSize = 200
    [void]$s.PropertiesToLoad.Add('distinguishedName')
    return $s.FindOne()
}

# SCCM AdminService (/wmi OData) as the current (regular) user. ${Class} MUST be braced:
# '?' is a valid variable-name char, so "$Class?" would drop the class from the URL.
function Invoke-AS([string]$Class, [string]$Filter, [string]$Select) {
    $rel = "wmi/${Class}?`$filter=" + [uri]::EscapeDataString($Filter) + $(if ($Select) { "&`$select=$Select" } else { '' })
    $p = @{ Uri = "https://$SiteServer/AdminService/$rel"; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

$bundle = [ordered]@{
    Query = $Identity; SamAccountName = ''; PrincipalName = ''; DisplayName = ''
    Manager = ''; Office = ''; Computers = @(); Errors = @()
}

# ---------- Step 1: AD user (forest-wide -> home-domain bind) ----------------------
$sam = if ($Identity -match '\\') { $Identity.Split('\')[-1] } else { $Identity }
$uFilter =
    if ($Identity -match '@') { "(&(objectClass=user)(userPrincipalName=$Identity))" }
    elseif ($Identity -match '\s') { "(&(objectClass=user)(displayName=$Identity))" }
    else { "(&(objectClass=user)(sAMAccountName=$sam))" }
try {
    $uHit = Find-GC $uFilter
    if (-not $uHit) { throw "no AD user matched '$Identity'." }
    $user = [ADSI]"LDAP://$([string]$uHit.Properties['distinguishedname'][0])"   # binds home domain
    $bundle.SamAccountName = [string]$user.Properties['samaccountname'][0]        # <- AD sAMAccountName (the SCCM key)
    $bundle.DisplayName    = [string]$user.Properties['displayname'][0]           # <- AD displayName
    $mgrDn = [string]$user.Properties['manager'][0]                               # <- AD manager (a DN)
    if ($mgrDn) { $bundle.Manager = Get-Cn $mgrDn }                               #    -> CN of that DN
    $office = @()                                                                 # <- AD physicalDeliveryOfficeName
    foreach ($k in 'physicaldeliveryofficename', 'streetaddress', 'l', 'st', 'postalcode') {  #    + streetAddress + l + st + postalCode
        $v = [string]$user.Properties[$k][0]; if ($v) { $office += $v }
    }
    $bundle.Office = ($office -join ', ')
    # <- AD msDS-PrincipalName (constructed; the 'DOMAIN\SAM' the ADUC pre-Win2000 box shows).
    try { $user.RefreshCache(@('msDS-PrincipalName')); $bundle.PrincipalName = [string]$user.Properties['msds-principalname'][0] } catch { }
    if ($bundle.SamAccountName) { $sam = $bundle.SamAccountName }   # authoritative SAM
} catch {
    $bundle.Errors += "AD user: $($_.Exception.Message)"
}

# ---------- Step 2: SCCM user -> WSID(s) -------------------------------------------
$wsids = @()
if ($sam) {
    try {
        $rows = Invoke-AS 'SMS_UserMachineRelationship' "endswith(UniqueUserName,'$sam')" 'UniqueUserName,ResourceName'
        # WSID <- SCCM SMS_UserMachineRelationship.ResourceName (client-filtered to the exact SAM tail).
        $wsids = @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
    } catch {
        $bundle.Errors += "SCCM affinity: $($_.Exception.Message)"
    }
}

# ---------- Step 3: per WSID -> BitLocker (forest-wide) ----------------------------
foreach ($wsid in $wsids) {
    $comp = [ordered]@{ Wsid = $wsid; Domain = ''; BitLocker = @(); Note = '' }
    try {
        $cHit = Find-GC "(&(objectClass=computer)(cn=$wsid))"
        if (-not $cHit) { $comp.Note = 'computer object not found in any domain'; $bundle.Computers += [pscustomobject]$comp; continue }
        $compDn = [string]$cHit.Properties['distinguishedname'][0]
        $comp.Domain = (($compDn -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')

        $bl = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
        $bl.Filter = '(objectClass=msFVE-RecoveryInformation)'
        'msfve-recoverypassword', 'whencreated' | ForEach-Object { [void]$bl.PropertiesToLoad.Add($_) }
        $keys = @($bl.FindAll())
        if ($keys.Count -gt 0) {
            # BitLocker key <- AD msFVE-RecoveryInformation.msFVE-RecoveryPassword (child objects of the computer).
            $comp.BitLocker = @($keys | ForEach-Object {
                    [pscustomobject]@{ Password = [string]$_.Properties['msfve-recoverypassword'][0]; Created = [string]$_.Properties['whencreated'][0] }
                })
        } else {
            $comp.Note = 'no BitLocker recovery objects (not escrowed to AD, or not readable)'
        }
    } catch {
        $comp.Note = "lookup failed: $($_.Exception.Message)"
    }
    $bundle.Computers += [pscustomobject]$comp
}

# ---------- Output ----------------------------------------------------------------
if ($AsJson) {
    $bundle | ConvertTo-Json -Depth 6
    return
}

# Renamed from 'H' - that collides with the built-in alias 'h' (Get-History), and
# aliases outrank functions in command lookup, so 'H "x"' ran Get-History.
function Hdr([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }

# Each line is  "Field : value   [<- exact source field]"  so the DONUT wiring is explicit.
Hdr 'Person'
Write-Host ("  Name       : {0}   [<- AD displayName]" -f $bundle.DisplayName)
Write-Host ("  SAM        : {0}   [<- AD sAMAccountName]" -f $bundle.SamAccountName)
Write-Host ("  DOMAIN\SAM : {0}   [<- AD msDS-PrincipalName]" -f $bundle.PrincipalName)
Write-Host ("  Manager    : {0}   [<- AD manager (CN of the DN)]" -f $bundle.Manager)
Write-Host ("  Office     : {0}   [<- AD physicalDeliveryOfficeName + streetAddress + l + st + postalCode]" -f $bundle.Office)

Hdr "Computers ($($bundle.Computers.Count))   [WSID <- SCCM SMS_UserMachineRelationship.ResourceName]"
if ($bundle.Computers.Count -eq 0) { Write-Host "  (no primary-device affinity rows for this user)" -ForegroundColor DarkGray }
foreach ($c in $bundle.Computers) {
    Write-Host ("  {0}   home domain: {1}   [<- AD computer DN]" -f $c.Wsid, $c.Domain) -ForegroundColor White
    if ($c.BitLocker.Count -gt 0) {
        foreach ($k in $c.BitLocker) { Write-Host ("      BitLocker : {0}   ({1})   [<- AD msFVE-RecoveryInformation.msFVE-RecoveryPassword]" -f $k.Password, $k.Created) -ForegroundColor Green }
    } else {
        Write-Host ("      {0}" -f $c.Note) -ForegroundColor DarkGray
    }
}
if ($bundle.Errors.Count -gt 0) {
    Hdr "Errors"
    $bundle.Errors | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
}
Write-Host ''
