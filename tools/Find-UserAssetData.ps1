#Requires -Version 5.1
<#
.SYNOPSIS
    Discovery dump: given a person, pull every asset field DONUT's "Lens" card wants,
    from its fastest source, and dump the full AD user + SCCM device records so any
    field we haven't pinned down yet (e.g. SiteID) reveals itself.

.DESCRIPTION
    Run as your REGULAR user (AD + SCCM in one context). For the given user it gathers:
      - AD user object  : manager, office address, and a FULL attribute dump (so SiteID /
                          department / extensionAttributeN / anything shows up).
      - SCCM affinity   : the user's WSID(s) via SMS_UserMachineRelationship (endswith,
                          the shape we proved works).
      - Per WSID (SCCM) : serial (PC_BIOS + SYSTEM_ENCLOSURE), model, and a curated
                          SMS_R_System dump (ADSiteName / SMSAssignedSites = SiteID
                          candidates).
      - Per WSID (AD)   : the computer object + BitLocker recovery keys
                          (msFVE-RecoveryInformation), if escrowed to AD and readable.
    Read-only. Nothing is changed anywhere.

.PARAMETER UserName
    Person to look up - SAM ('U0073097') or DOMAIN\SAM ('PRODUCTION\U0073097'). Defaults
    to the account running the script. Use a colleague who has a machine + BitLocker for
    the richest sample.

.PARAMETER SiteServer
    AdminService host. Default 'sccm01.contoso.com'.

.NOTES
    If the BitLocker section is empty, your account may lack the delegated read on
    msFVE-RecoveryInformation - note it (production reads BitLocker as the admin account).

.EXAMPLE
    pwsh -File tools\Find-UserAssetData.ps1 -UserName 'PRODUCTION\U0073097'
#>
[CmdletBinding()]
param(
    [string] $UserName   = "$env:USERNAME",
    [string] $SiteServer = 'sccm01.contoso.com'
)

$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
$sam = if ($UserName -match '\\') { $UserName.Split('\')[-1] } else { $UserName }

function Section([string]$t) { Write-Host ''; Write-Host "== $t " -ForegroundColor Cyan -NoNewline; Write-Host ('=' * [Math]::Max(0, 72 - $t.Length)) -ForegroundColor DarkCyan }
function Field([string]$k, $v) { Write-Host ("  {0,-26} " -f $k) -ForegroundColor Gray -NoNewline; Write-Host $v }
function Note([string]$m) { Write-Host "  $m" -ForegroundColor DarkGray }
function Bad([string]$m)  { Write-Host "  $m" -ForegroundColor Red }

function Invoke-AS([string]$Rel) {
    $p = @{ Uri = "https://$SiteServer/AdminService/$Rel"; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return Invoke-RestMethod @p
}
function AS-Value([string]$Class, [string]$Filter, [string]$Select) {
    # /wmi query; returns the .value array or $null on error (with the URL + status noted).
    # ${Class} MUST be braced: '?' is a valid variable-name char (cf. $?), so "$Class?"
    # would parse as a variable named 'Class?' (empty) and drop the class from the URL.
    $rel = "wmi/${Class}?`$filter=" + [uri]::EscapeDataString($Filter) + $(if ($Select) { "&`$select=$Select" } else { '' })
    try {
        return @((Invoke-AS $rel).value)
    } catch {
        $code = 0
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        $hint = switch ($code) {
            { $_ -eq 401 -or $_ -eq 403 } { '  <- this identity lacks ConfigMgr RBAC (admin account?). Run as your regular user.' }
            404 { '  <- 404 usually means the class is RBAC-hidden for this identity (admin account?); check the Run-as line. If you ARE the regular user, send me the URL below.' }
            default { '' }
        }
        Bad "  ${Class}: HTTP $code$hint"
        Note "    URL: https://$SiteServer/AdminService/$rel"
        return $null
    }
}
function Find-AD([string]$Filter, [string[]]$Props) {
    $s = [ADSISearcher]$Filter
    if ($Props) { $s.PropertiesToLoad.Clear(); $Props | ForEach-Object { [void]$s.PropertiesToLoad.Add($_) } }
    return $s.FindOne()
}
function CN-Of([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

Write-Host ''
Write-Host "Asset discovery for '$sam'  (via AD + AdminService on $SiteServer)" -ForegroundColor White
Write-Host "Run as: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)" -ForegroundColor DarkGray

# =============================== AD USER ==========================================
Section 'AD user object'
$siteCandidates = [ordered]@{}
$userRes = Find-AD "(&(objectClass=user)(sAMAccountName=$sam))" $null
if (-not $userRes) {
    Bad "No AD user found for sAMAccountName=$sam."
} else {
    $up = $userRes.Properties
    # Highlighted fields DONUT wants.
    if ($up['displayname']) { Field 'DisplayName' ([string]$up['displayname'][0]) }
    if ($up['manager'])     { $mdn = [string]$up['manager'][0]; Field 'Manager' "$(CN-Of $mdn)  <$mdn>" }
    $office = @()
    foreach ($k in 'physicaldeliveryofficename', 'streetaddress', 'l', 'st', 'postalcode', 'co', 'telephonenumber') {
        if ($up[$k]) { $office += "${k}=$([string]$up[$k][0])" }
    }
    if ($office) { Field 'Office / address' ($office -join '  |  ') }

    # SiteID candidates from AD (flag likely holders so you can point at the right one).
    foreach ($k in 'department', 'company', 'physicaldeliveryofficename', 'extensionattribute1', 'extensionattribute2', 'extensionattribute3', 'extensionattribute4', 'extensionattribute5') {
        if ($up[$k]) { $siteCandidates["AD:$k"] = [string]$up[$k][0] }
    }

    Note ''
    Note "-- FULL AD attribute dump (scan this for SiteID / anything else) --"
    foreach ($name in ($up.PropertyNames | Sort-Object)) {
        $disp = ($up[$name] | ForEach-Object { if ($_ -is [byte[]]) { "<binary $($_.Length)b>" } else { "$_" } }) -join ' | '
        if ($name -match 'site') { $siteCandidates["AD:$name"] = $disp }
        Write-Host ("    {0,-28} {1}" -f $name, $disp)
    }
}

# =============================== SCCM WSIDs =======================================
Section 'SCCM user -> WSID(s)  (SMS_UserMachineRelationship, endswith)'
$wsids = @()
$rel = AS-Value 'SMS_UserMachineRelationship' "endswith(UniqueUserName,'$sam')" 'UniqueUserName,ResourceName'
if ($null -ne $rel) {
    # Exact-tail guard so 'U0073097' can't match '...\XU0073097'.
    $wsids = @($rel | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
    if ($wsids.Count -gt 0) { $wsids | ForEach-Object { Field 'WSID' $_ } }
    else { Note "No affinity rows exactly matching '$sam' (of $($rel.Count) endswith hits)." }
}

# =============================== PER-WSID DETAIL ==================================
foreach ($wsid in $wsids) {
    Section "Computer: $wsid"

    # Resolve ResourceID (Name eq - no backslash, safe).
    $rid = $null
    $sys = AS-Value 'SMS_R_System' "Name eq '$wsid'" 'ResourceID,Name,ADSiteName,SMSAssignedSites,DistinguishedName,LastLogonUserName,OperatingSystemNameandVersion,ResourceDomainORWorkgroup'
    if ($sys -and $sys.Count -gt 0) {
        $d = $sys[0]
        $rid = $d.ResourceID
        Field 'ResourceID' $rid
        Field 'AD site (ADSiteName)' ([string]$d.ADSiteName)
        Field 'SMS assigned site(s)' (@($d.SMSAssignedSites) -join ', ')
        Field 'Last logon user' ([string]$d.LastLogonUserName)
        Field 'OS' ([string]$d.OperatingSystemNameandVersion)
        Field 'Computer DN' ([string]$d.DistinguishedName)
        if ($d.ADSiteName)       { $siteCandidates["SCCM:ADSiteName@$wsid"] = [string]$d.ADSiteName }
        if ($d.SMSAssignedSites) { $siteCandidates["SCCM:SMSAssignedSites@$wsid"] = (@($d.SMSAssignedSites) -join ', ') }
    } else {
        Bad "  Could not resolve ResourceID for $wsid in SMS_R_System."
    }

    if ($rid) {
        # Serial - two classes, take whichever is populated.
        foreach ($cls in 'SMS_G_System_PC_BIOS', 'SMS_G_System_SYSTEM_ENCLOSURE') {
            $s = AS-Value $cls "ResourceID eq $rid" 'SerialNumber'
            if ($s -and $s.Count -gt 0 -and $s[0].SerialNumber) { Field "Serial ($cls)" ([string]$s[0].SerialNumber) }
        }
        # Model.
        $cs = AS-Value 'SMS_G_System_COMPUTER_SYSTEM' "ResourceID eq $rid" 'Manufacturer,Model'
        if ($cs -and $cs.Count -gt 0) { Field 'Make / model' "$([string]$cs[0].Manufacturer) $([string]$cs[0].Model)" }
    }

    # BitLocker recovery from AD (msFVE-RecoveryInformation under the computer object).
    $compRes = Find-AD "(&(objectClass=computer)(cn=$wsid))" @('distinguishedName')
    if (-not $compRes) {
        Note "BitLocker: computer object '$wsid' not found in AD."
    } else {
        $compDn = [string]$compRes.Properties['distinguishedname'][0]
        try {
            $bl = [ADSISearcher]'(objectClass=msFVE-RecoveryInformation)'
            $bl.SearchRoot = [ADSI]"LDAP://$compDn"
            $bl.PropertiesToLoad.Clear(); 'msfve-recoverypassword', 'msfve-recoveryguid', 'whencreated' | ForEach-Object { [void]$bl.PropertiesToLoad.Add($_) }
            $keys = @($bl.FindAll())
            if ($keys.Count -gt 0) {
                foreach ($k in $keys) {
                    $pw = [string]$k.Properties['msfve-recoverypassword'][0]
                    $when = [string]$k.Properties['whencreated'][0]
                    Field 'BitLocker key' "$pw   ($when)"
                }
            } else {
                Note "BitLocker: no recovery objects under $wsid (not escrowed to AD, or your account can't read them)."
            }
        } catch {
            Bad "  BitLocker read failed: $($_.Exception.Message)"
        }
    }
}

# =============================== SITEID SUMMARY ===================================
Section 'SiteID candidates (point me at the right one)'
if ($siteCandidates.Count -eq 0) {
    Note "Nothing obvious surfaced - check the full AD dump above for a custom attribute."
} else {
    foreach ($k in $siteCandidates.Keys) { Field $k $siteCandidates[$k] }
}

Write-Host ''
Note "Send this back. Tell me which line is 'SiteID', confirm BitLocker showed keys, and which"
Note "Serial class was populated - then I'll wire each field from its fastest source into the Lens."
Write-Host ''
