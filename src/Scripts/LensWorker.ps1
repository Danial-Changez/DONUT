#Requires -Version 5.1
<#
.SYNOPSIS
    De-elevated inner worker for the user Lens: resolves a person to their directory
    facts + SCCM-assigned devices + BitLocker keys, and writes the bundle encrypted.

.DESCRIPTION
    Runs as the INTERACTIVE (regular) user - launched by LensLookupWorker via a
    de-elevated scheduled task - because SCCM (AdminService) and BitLocker (AD) are
    readable only by that account, while DONUT itself runs elevated as the admin
    account. Pipeline, ordered for perceived speed:
      1. The SCCM affinity query (person -> WSIDs) starts on a THREAD JOB as soon as
         a SAM is known - the finder's -Sam hint lets it run in parallel with the AD
         user read. It is the ONLY SCCM call (the /wmi route's OData translator
         rejects richer filters, answering 404).
      2. AD user, forest-wide via the Global Catalog then home-domain bind; written
         out immediately as partial 1 so the UI shows the directory facts early.
      3. When affinity lands, name-only device rows go out as partial 2; then each
         WSID's AD object supplies operatingSystem, lastLogonTimestamp and the
         msFVE-* BitLocker children for the final bundle.

.PARAMETER Identity
    UPN / DOMAIN\SAM / bare SAM / display name to resolve.

.PARAMETER SiteServer
    SCCM AdminService host (e.g. sccm01.contoso.com).

.PARAMETER ResultPath
    File to write the encrypted bundle to; 'partial-N' + 'key' siblings are derived
    from its folder (the ACL-locked exchange dir PersonLensService created).

.PARAMETER Sam
    Optional sAMAccountName hint from the finder row, so the affinity query can start
    before the AD user read resolves it.

.NOTES
    Read-only against AD/SCCM. Uses raw LDAP/DirectorySearcher (no AD module) + the
    AdminService REST endpoint (no ConfigMgr module / PSDrive).

    The bundle contains BitLocker recovery keys, so it never touches disk in the clear:
    payloads are AES-256-CBC (PKCS7) over the UTF-8 JSON, keyed by the per-lookup
    key.bin (32-byte key + 16-byte IV) the parent wrote into the exchange dir. Writes
    are atomic (write .tmp, rename) so the parent never reads a half-written file.
    MUST match PersonLensService.ProtectText/UnprotectText.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Identity,
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $ResultPath,
    [string] $Sam = ''
)

$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$exchangeDir = Split-Path -Parent $ResultPath
$script:KeyIv = $null
try { $script:KeyIv = [IO.File]::ReadAllBytes((Join-Path $exchangeDir 'key.bin')) } catch { }

function Get-Cn([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

# AES-256-CBC over the UTF-8 JSON (format documented in .NOTES), written atomically.
# No key = plaintext fallback so the parent still gets a readable error bundle.
function Write-LensBundle([string]$path, [string]$json) {
    $bytes =
        if ($script:KeyIv -and $script:KeyIv.Length -eq 48) {
            $aes = [System.Security.Cryptography.Aes]::Create()
            try {
                $aes.Key = [byte[]]($script:KeyIv[0..31])
                $aes.IV = [byte[]]($script:KeyIv[32..47])
                $enc = $aes.CreateEncryptor()
                $plain = [Text.Encoding]::UTF8.GetBytes($json)
                $enc.TransformFinalBlock($plain, 0, $plain.Length)
            }
            finally { $aes.Dispose() }
        }
        else { [Text.Encoding]::UTF8.GetBytes($json) }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllBytes($tmp, $bytes)
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

# Sequential partials (partial-1.bin, partial-2.bin, ...) the parent streams to the UI.
$script:PartialSeq = 0
function Write-LensPartial([hashtable]$b) {
    $script:PartialSeq++
    try { Write-LensBundle (Join-Path $exchangeDir ("partial-{0}.bin" -f $script:PartialSeq)) ($b | ConvertTo-Json -Depth 6) } catch { }
}

$forestNc = [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0]
function Find-Gc([string]$Filter) {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.SearchRoot = [ADSI]"GC://$forestNc"
    $s.Filter = $Filter
    $s.PageSize = 200
    [void]$s.PropertiesToLoad.Add('distinguishedName')
    return $s.FindOne()
}

# The SCCM affinity query, self-contained so it can run on a thread job in parallel
# with the AD user read. endswith on the forest-unique SAM is the only filter shape
# this AdminService accepts (eq + backslash, or-ed filters, etc. all answer 404).
$script:AffinityScript = {
    param($server, $samValue)
    $p = @{
        Uri = "https://$server/AdminService/wmi/SMS_UserMachineRelationship?`$filter=" +
              [uri]::EscapeDataString("endswith(UniqueUserName,'$samValue')") +
              "&`$select=UniqueUserName,ResourceName"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

$script:AffinityJob = $null
function Start-AffinityJob([string]$samValue) {
    if ($script:AffinityJob -or [string]::IsNullOrWhiteSpace($samValue)) { return }
    try { $script:AffinityJob = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $SiteServer, $samValue }
    catch { $script:AffinityJob = $null }   # ThreadJob unavailable -> inline fallback below
}

$bundle = [ordered]@{
    upn = ''; sam = ''; displayName = ''; email = ''; manager = ''; office = ''
    devices = @(); errors = @()
}

# Start affinity NOW when the SAM is already trustworthy: the finder's hint, a
# DOMAIN\SAM identity, or a bare SAM (no '@'/space). A UPN/display-name identity
# waits for the AD read to resolve it.
$samGuess =
    if ($Sam) { $Sam }
    elseif ($Identity -match '\\') { $Identity.Split('\')[-1] }
    elseif ($Identity -notmatch '[@\s]') { $Identity }
    else { '' }
Start-AffinityJob $samGuess

# --- AD user (forest-wide GC -> home-domain bind) ---------------------------------
$sam = $samGuess
$uFilter =
    if ($Identity -match '@') { "(&(objectClass=user)(userPrincipalName=$Identity))" }
    elseif ($Identity -match '\s') { "(&(objectClass=user)(displayName=$Identity))" }
    else { "(&(objectClass=user)(sAMAccountName=$samGuess))" }
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

# Partial 1 (directory facts): the parent streams it to the UI so the pane fills in
# ~1-2s while the affinity/BitLocker work continues below.
Write-LensPartial $bundle

# UPN/display-name pick: the SAM only became known from the AD read - start affinity now.
Start-AffinityJob $sam

# --- SCCM user -> WSID(s): collect the parallel affinity result --------------------
$wsids = @()
if ($sam) {
    $rows = $null
    try {
        if ($script:AffinityJob) {
            if (Wait-Job -Job $script:AffinityJob -Timeout 45) { $rows = Receive-Job -Job $script:AffinityJob -ErrorAction Stop }
            else { throw 'timed out after 45s.' }
        }
        else {
            $rows = & $script:AffinityScript $SiteServer $sam
        }
    }
    catch {
        $bundle.errors += "SCCM affinity (SMS_UserMachineRelationship, endswith '$sam'): $($_.Exception.Message)"
    }
    finally {
        if ($script:AffinityJob) { Remove-Job -Job $script:AffinityJob -Force -ErrorAction SilentlyContinue }
    }
    $wsids = @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
}

# Partial 2 (name-only device rows) so the devices appear the moment affinity lands;
# the per-WSID AD reads below fill in OS / last-logon / BitLocker behind them.
if ($wsids.Count -gt 0) {
    $bundle.devices = @($wsids | ForEach-Object {
            [ordered]@{ name = $_; os = ''; lastLogon = ''; domain = ''; note = 'loading details…'; bitLockerKeys = @() }
        })
    Write-LensPartial $bundle
}

# --- Per WSID: OS / last-logon / BitLocker, all from the computer's AD object --------
$devices = [System.Collections.Generic.List[object]]::new()
foreach ($wsid in $wsids) {
    $dev = [ordered]@{ name = $wsid; os = ''; lastLogon = ''; domain = ''; note = ''; bitLockerKeys = @() }

    # GC-locate the computer forest-wide, then read from its home-domain object.
    try {
        $cHit = Find-Gc "(&(objectClass=computer)(cn=$wsid))"
        if ($cHit) {
            $compDn = [string]$cHit.Properties['distinguishedname'][0]
            $dev.domain = (($compDn -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')

            # OS + last domain logon (lastLogonTimestamp: replicated, up to ~14 days
            # coarse - good enough for "which of these machines is current").
            $cs = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
            $cs.SearchScope = 'Base'
            $cs.Filter = '(objectClass=*)'
            'operatingsystem', 'lastlogontimestamp' | ForEach-Object { [void]$cs.PropertiesToLoad.Add($_) }
            $c = $cs.FindOne()
            if ($c) {
                if ($c.Properties['operatingsystem'].Count -gt 0) { $dev.os = [string]$c.Properties['operatingsystem'][0] }
                if ($c.Properties['lastlogontimestamp'].Count -gt 0) {
                    $ft = [int64]$c.Properties['lastlogontimestamp'][0]
                    if ($ft -gt 0) { $dev.lastLogon = [datetime]::FromFileTimeUtc($ft).ToString('o') }
                }
            }

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
    Write-LensBundle $ResultPath ($bundle | ConvertTo-Json -Depth 6)
}
catch {
    # Last resort: write a minimal error bundle so the caller never hangs on a missing file.
    try { Write-LensBundle $ResultPath (@{ errors = @("LensWorker could not write the result: $($_.Exception.Message)") } | ConvertTo-Json) } catch { }
}
