#Requires -Version 5.1
<#
.SYNOPSIS
    Persistent de-elevated Lens agent: serves person -> devices lookups for the
    app's whole lifetime, so a pick costs only query time.

.DESCRIPTION
    Started ONCE (at app startup, or on demand when its heartbeat goes stale) by
    PersonLensService.EnsureAgent via a scheduled task - Interactive logon = the
    logged-on token, RunLevel Limited, wrapped in conhost --headless - because the
    Lens data (SCCM affinity + BitLocker) is readable only by the operator's regular
    account while DONUT runs elevated as the admin account. Being persistent removes
    the per-pick task registration + pwsh cold start (~2-4s); on boot the agent
    pre-warms its libraries (DirectoryServices/GC bind, ThreadJob, the AdminService
    TLS/Kerberos channel) in parallel with DONUT's own startup.

    Protocol over the ACL-locked exchange dir (every payload AES-256-CBC with the
    session key.bin; writes atomic tmp+rename):
      request-<id>.bin    <- { identity, sam, siteServer }   (parent writes)
      partial-<id>-1.bin  -> directory facts                 (agent writes)
      partial-<id>-2.bin  -> name-only device rows
      result-<id>.bin     -> the full bundle
    The agent deletes each request once read; the parent deletes the responses it
    consumed; anything older than 10 minutes is swept as abandoned.

    Exits when stop.flag appears, the parent process dies, or the exchange dir is
    deleted. heartbeat.txt is touched every ~2s from a BACKGROUND thread (not the serve
    loop), so a lookup in progress never lets the beat go stale - otherwise EnsureAgent's
    15s staleness check would tear a busy agent down mid-lookup. A genuinely gone agent
    still stops beating, so EnsureAgent can still detect and restart it.

.PARAMETER ExchangeDir
    The ACL-locked %ProgramData%\DONUT\lens-agent dir PersonLensService created.

.PARAMETER ParentPid
    The DONUT process id; the agent exits when it disappears.

.PARAMETER SiteServer
    SCCM AdminService host, used for the startup channel warm; each request carries
    its own (normally identical) value.

.NOTES
    Read-only against AD/SCCM. Raw LDAP/DirectorySearcher (no AD module) + the
    AdminService REST endpoint (no ConfigMgr module / PSDrive). The affinity query
    is the ONLY SCCM call (the /wmi route's OData translator rejects richer
    filters, answering 404); everything per-device comes from the computer's AD
    object. Crypto format MUST match PersonLensService.ProtectText/UnprotectText.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ExchangeDir,
    [Parameter(Mandatory)] [int]    $ParentPid,
    [string] $SiteServer = ''
)

$ErrorActionPreference = 'Continue'
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

$script:KeyIv = $null
try { $script:KeyIv = [IO.File]::ReadAllBytes((Join-Path $ExchangeDir 'key.bin')) } catch { }
if (-not $script:KeyIv -or $script:KeyIv.Length -ne 48) { return }   # no session key -> nothing to serve

# --- crypto + atomic file I/O (format shared with PersonLensService) ---------------
function Protect-Text([string]$text) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = [byte[]]($script:KeyIv[0..31]); $aes.IV = [byte[]]($script:KeyIv[32..47])
        $enc = $aes.CreateEncryptor()
        $plain = [Text.Encoding]::UTF8.GetBytes($text)
        return $enc.TransformFinalBlock($plain, 0, $plain.Length)
    }
    finally { $aes.Dispose() }
}

function Unprotect-File([string]$path) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = [byte[]]($script:KeyIv[0..31]); $aes.IV = [byte[]]($script:KeyIv[32..47])
        $dec = $aes.CreateDecryptor()
        $blob = [IO.File]::ReadAllBytes($path)
        return [Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($blob, 0, $blob.Length))
    }
    finally { $aes.Dispose() }
}

function Write-LensBundle([string]$path, [string]$json) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllBytes($tmp, (Protect-Text $json))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-Cn([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

function Find-Gc([string]$Filter) {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.SearchRoot = [ADSI]"GC://$($script:ForestNc)"
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

# Sequential partials (partial-<id>-1, -2, ...) the parent streams to the UI.
function Write-LensPartial([hashtable]$b, [string]$reqId, [int]$seq) {
    try { Write-LensBundle (Join-Path $ExchangeDir ("partial-{0}-{1}.bin" -f $reqId, $seq)) ($b | ConvertTo-Json -Depth 6) } catch { }
}

# --- one lookup: the validated pipeline, emitting partials as it goes ---------------
function Resolve-Lens([string]$identity, [string]$samHint, [string]$server, [string]$reqId) {
    $bundle = [ordered]@{
        upn = ''; sam = ''; displayName = ''; email = ''; manager = ''; office = ''
        devices = @(); errors = @()
    }

    # Affinity starts NOW when the SAM is already trustworthy: the finder's hint, a
    # DOMAIN\SAM identity, or a bare SAM. A UPN/display-name identity waits for AD.
    $samGuess =
        if ($samHint) { $samHint }
        elseif ($identity -match '\\') { $identity.Split('\')[-1] }
        elseif ($identity -notmatch '[@\s]') { $identity }
        else { '' }
    $affinityJob = $null
    if ($samGuess -and $server) {
        try { $affinityJob = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $server, $samGuess } catch { $affinityJob = $null }
    }

    # AD user (forest-wide GC -> home-domain bind).
    $sam = $samGuess
    $uFilter =
        if ($identity -match '@') { "(&(objectClass=user)(userPrincipalName=$identity))" }
        elseif ($identity -match '\s') { "(&(objectClass=user)(displayName=$identity))" }
        else { "(&(objectClass=user)(sAMAccountName=$samGuess))" }
    try {
        $uHit = Find-Gc $uFilter
        if (-not $uHit) { throw "no AD user matched '$identity'." }
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

    # Partial 1: directory facts.
    Write-LensPartial $bundle $reqId 1

    # UPN/display-name pick: the SAM only became known from the AD read - start now.
    if (-not $affinityJob -and $sam -and $server) {
        try { $affinityJob = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $server, $sam } catch { $affinityJob = $null }
    }

    # SCCM user -> WSID(s): collect the parallel affinity result.
    $wsids = @()
    if ($sam -and $server) {
        $rows = $null
        try {
            if ($affinityJob) {
                if (Wait-Job -Job $affinityJob -Timeout 45) { $rows = Receive-Job -Job $affinityJob -ErrorAction Stop }
                else { throw 'timed out after 45s.' }
            }
            else {
                $rows = & $script:AffinityScript $server $sam
            }
        }
        catch {
            $bundle.errors += "SCCM affinity (SMS_UserMachineRelationship, endswith '$sam'): $($_.Exception.Message)"
        }
        finally {
            if ($affinityJob) { Remove-Job -Job $affinityJob -Force -ErrorAction SilentlyContinue }
        }
        $wsids = @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } | ForEach-Object { $_.ResourceName } | Where-Object { $_ } | Select-Object -Unique)
    }

    # Partial 2: name-only device rows the moment affinity lands.
    if ($wsids.Count -gt 0) {
        $bundle.devices = @($wsids | ForEach-Object {
                [ordered]@{ name = $_; os = ''; lastLogon = ''; domain = ''; note = 'loading details…'; bitLockerKeys = @() }
            })
        Write-LensPartial $bundle $reqId 2
    }

    # Per WSID: OS / last-logon / BitLocker, all from the computer's AD object.
    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($wsid in $wsids) {
        $dev = [ordered]@{ name = $wsid; os = ''; lastLogon = ''; domain = ''; note = ''; bitLockerKeys = @() }
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

    Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) ($bundle | ConvertTo-Json -Depth 6)
}

# --- pre-warm (parallel with DONUT's startup; heartbeat first so the parent unblocks) --
$heartbeatPath = Join-Path $ExchangeDir 'heartbeat.txt'
$stopPath = Join-Path $ExchangeDir 'stop.flag'
try { [IO.File]::WriteAllText($heartbeatPath, [datetime]::UtcNow.ToString('o')) } catch { return }

# Beat + parent/stop watchdog on a BACKGROUND thread. A lookup blocks the serve loop for
# its whole duration (tens of seconds), so beating from that loop would let the heartbeat
# go stale mid-lookup - and EnsureAgent (15s staleness = dead) would then tear this live
# agent down mid-lookup, stranding the request. A dedicated beater keeps a busy agent
# looking alive. Best-effort: without ThreadJob the serve loop beats between lookups.
try { Import-Module ThreadJob -ErrorAction SilentlyContinue } catch { }
$script:HeartbeatJob = $null
try {
    $script:HeartbeatJob = Start-ThreadJob -ScriptBlock {
        param($beatPath, $stopPath, $parentPid)
        while ($true) {
            try { [IO.File]::WriteAllText($beatPath, [datetime]::UtcNow.ToString('o')) } catch { break }   # dir gone
            if ([IO.File]::Exists($stopPath)) { break }
            try { $null = [System.Diagnostics.Process]::GetProcessById($parentPid) }
            catch { try { [IO.File]::WriteAllText($stopPath, 'parent-exited') } catch { }; break }   # DONUT closed
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $heartbeatPath, $stopPath, $ParentPid
} catch { $script:HeartbeatJob = $null }

$script:ForestNc = ''
try { $script:ForestNc = [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0] } catch { }
try { $null = Find-Gc '(objectClass=domain)' } catch { }              # bind the GC once (ThreadJob imported above)
if ($SiteServer) {
    # Throwaway affinity primes TLS + Kerberos to the AdminService (result discarded).
    try { $null = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $SiteServer, 'zzz-donut-warm' } catch { }
}

# --- serve ---------------------------------------------------------------------------
$lastBeat = [datetime]::MinValue
$lastParentCheck = [datetime]::MinValue
while ($true) {
    if (Test-Path -LiteralPath $stopPath) { break }
    if (-not (Test-Path -LiteralPath $ExchangeDir)) { break }   # dir purged out from under us -> exit

    $now = [datetime]::UtcNow
    # The background heartbeat job owns the beat + parent watchdog; only beat from the serve
    # loop as the no-ThreadJob fallback, so the two never race on heartbeat.txt (a concurrent
    # write could throw and be misread as "the dir vanished").
    if (-not $script:HeartbeatJob) {
        if (($now - $lastBeat).TotalSeconds -ge 2) {
            $lastBeat = $now
            try { [IO.File]::WriteAllText($heartbeatPath, $now.ToString('o')) }
            catch { break }   # exchange dir gone (parent purged it) -> exit
        }
        if (($now - $lastParentCheck).TotalSeconds -ge 3) {
            $lastParentCheck = $now
            if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }   # DONUT closed
        }
    }

    $requests = @(Get-ChildItem -Path $ExchangeDir -Filter 'request-*.bin' -File -ErrorAction SilentlyContinue |
            Sort-Object CreationTimeUtc)
    foreach ($reqFile in $requests) {
        $reqId = $reqFile.BaseName -replace '^request-', ''
        $req = $null
        try { $req = Unprotect-File $reqFile.FullName | ConvertFrom-Json }
        catch { }
        Remove-Item -LiteralPath $reqFile.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $req) { continue }
        try {
            Resolve-Lens ([string]$req.identity) ([string]$req.sam) ([string]$req.siteServer) $reqId
        }
        catch {
            # Never leave the parent hanging: always answer, even if only with the error.
            try { Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) (@{ errors = @("Lens agent: $($_.Exception.Message)") } | ConvertTo-Json) } catch { }
        }
    }

    # Sweep responses a parent abandoned (e.g. it timed out and moved on).
    Get-ChildItem -Path $ExchangeDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(partial|result)-' -and $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 150
}

if ($script:HeartbeatJob) { Remove-Job -Job $script:HeartbeatJob -Force -ErrorAction SilentlyContinue }
