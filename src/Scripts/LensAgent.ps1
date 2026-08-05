#Requires -Version 5.1
<#
.SYNOPSIS
    Persistent de-elevated Lens agent: serves person -> devices lookups for the
    app's whole lifetime, so each costs only query time.

.DESCRIPTION
    Started once (at app startup, or on demand when its heartbeat goes stale) by
    PersonLensService.EnsureAgent via a scheduled task - Interactive logon = the
    logged-on token, RunLevel Limited, wrapped in conhost --headless - because the
    Lens data (SCCM affinity + BitLocker) is readable only by the operator's regular
    account while DONUT runs elevated as the admin account. Being persistent removes
    the per-pick task registration + pwsh cold start (~2-4s); on boot the agent
    pre-warms its libraries (DirectoryServices/GC bind, ThreadJob, the AdminService
    TLS/Kerberos channel) in parallel with DONUT's own startup, and reuses those warm
    binds for every later lookup. (The finder's AD search is separate - it runs
    in-process on the pool via AdSearchWorker, not through this agent.)

    Protocol over the ACL-locked exchange dir (every payload AES-256-CBC with the
    session key.bin; writes atomic tmp+rename):
      request-<id>.bin    <- { identity, sam, siteServer }   (parent writes)
      partial-<id>-1.bin  -> directory facts                 (agent writes)
      partial-<id>-2.bin  -> name-only device rows
      result-<id>.bin     -> lookup bundle
    The agent deletes each request once read; the parent deletes the responses it
    consumed; anything older than 10 minutes is swept as abandoned.

    A lookup takes tens of seconds, so it is offloaded to a ThreadJob (falling back to
    inline if that fails) and the serve loop stays free to accept the next request. The
    lookup pipeline and all exchange helpers live in LensAgent.Common.ps1, dot-sourced
    here and into each lookup ThreadJob.

    Exits when stop.flag appears, the parent process dies, or the exchange dir is
    deleted. heartbeat.txt is touched every ~2s from a background thread (not the serve
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
    AdminService REST endpoint (no ConfigMgr module / PSDrive). The SCCM calls are
    the affinity query and the per-device hardware pass (ResourceID-shaped; the
    /wmi route's OData translator rejects richer string filters with 404);
    everything else per-device comes from the computer's AD object. The crypto
    format must match PersonLensService.ProtectText/UnprotectText.
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
# No session key -> nothing to serve.
if (-not $script:KeyIv -or $script:KeyIv.Length -ne 48) { return }

# Exchange crypto/IO + the lookup (Resolve-Lens) helpers.
$commonPath = Join-Path $PSScriptRoot 'LensAgent.Common.ps1'
. $commonPath

# --- pre-warm (parallel with DONUT's startup; heartbeat first so the parent unblocks) --
$heartbeatPath = Join-Path $ExchangeDir 'heartbeat.txt'
$stopPath = Join-Path $ExchangeDir 'stop.flag'
try { [IO.File]::WriteAllText($heartbeatPath, [datetime]::UtcNow.ToString('o')) } catch { return }

# Beating from the serve loop would let EnsureAgent tear a busy agent down mid-lookup.
try { Import-Module ThreadJob -ErrorAction SilentlyContinue } catch { }
$script:HeartbeatJob = $null
try {
    $script:HeartbeatJob = Start-ThreadJob -ScriptBlock {
        param($beatPath, $stopPath, $parentPid)
        while ($true) {
            # A failed beat write means the exchange dir is gone.
            try { [IO.File]::WriteAllText($beatPath, [datetime]::UtcNow.ToString('o')) }
            catch { break }
            if ([IO.File]::Exists($stopPath)) { break }
            # A missing parent process means DONUT closed.
            try { $null = [System.Diagnostics.Process]::GetProcessById($parentPid) }
            catch { try { [IO.File]::WriteAllText($stopPath, 'parent-exited') } catch { }; break }
            Start-Sleep -Seconds 2
        }
    } -ArgumentList $heartbeatPath, $stopPath, $ParentPid
}
catch { $script:HeartbeatJob = $null }

$script:ForestNc = ''
# Blank on failure is the handled case: Find-Gc falls back without a naming context.
try { $script:ForestNc = Get-LensForestNc } catch { $script:ForestNc = '' }
# Bind the GC once (ThreadJob imported above).
try { $null = Find-Gc '(objectClass=domain)' } catch { }
if ($SiteServer) {
    # Throwaway affinity primes TLS + Kerberos to the AdminService (result discarded).
    try {
        $null = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $SiteServer, 'zzz-donut-warm'
    }
    catch { }
}

# --- Serve loop ---
# Lookup ThreadJobs run off the loop so a slow lookup never blocks a fast search.
$lookupJobs = [System.Collections.Generic.List[object]]::new()
$lastBeat = [datetime]::MinValue
$lastParentCheck = [datetime]::MinValue
while ($true) {
    if (Test-Path -LiteralPath $stopPath) { break }
    # Dir purged out from under us -> exit.
    if (-not (Test-Path -LiteralPath $ExchangeDir)) { break }

    $now = [datetime]::UtcNow
    # Fallback only, so it never races the background beater on heartbeat.txt.
    if (-not $script:HeartbeatJob) {
        if (($now - $lastBeat).TotalSeconds -ge 2) {
            $lastBeat = $now
            try { [IO.File]::WriteAllText($heartbeatPath, $now.ToString('o')) }
            catch { break }   # Exchange dir gone (the parent purged it), so exit.
        }
        if (($now - $lastParentCheck).TotalSeconds -ge 3) {
            $lastParentCheck = $now
            # A missing parent process means DONUT closed.
            if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { break }
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
            # Answering inline beats N requests through this loop's 150ms pass.
            if ([string]$req.kind -eq 'owner') {
                $ownerJson = Resolve-MachineOwnerBatch -wsids @($req.machines) -server ([string]$req.siteServer)
                Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $ownerJson
                continue
            }
            # Falls back to inline so a lookup is never silently dropped.
            $offloaded = $false
            try {
                $job = Start-ThreadJob -ScriptBlock {
                    param($commonPath, $exchangeDir, $keyIv, $forestNc, $identity, $samHint, $server, $reqId)
                    Import-Module ThreadJob -ErrorAction SilentlyContinue
                    . $commonPath
                    $script:KeyIv = $keyIv
                    $script:ForestNc = $forestNc
                    $ExchangeDir = $exchangeDir
                    Resolve-Lens -identity $identity -samHint $samHint -server $server -reqId $reqId
                } -ArgumentList $commonPath, $ExchangeDir, $script:KeyIv, $script:ForestNc,
                ([string]$req.identity), ([string]$req.sam), ([string]$req.siteServer), $reqId
                $lookupJobs.Add($job)
                $offloaded = $true
            }
            catch { $offloaded = $false }
            if (-not $offloaded) {
                Resolve-Lens -identity ([string]$req.identity) -samHint ([string]$req.sam) `
                    -server ([string]$req.siteServer) -reqId $reqId
            }
        }
        catch {
            # Never leave the parent hanging: always answer, even if only with the error.
            try {
                $errJson = @{ errors = @("Lens agent: $($_.Exception.Message)") } | ConvertTo-Json
                Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $errJson
            }
            catch { }
        }
    }

    # Reap finished lookup ThreadJobs (each wrote its own result-<id>.bin).
    for ($i = $lookupJobs.Count - 1; $i -ge 0; $i--) {
        if ([string]$lookupJobs[$i].State -in @('Completed', 'Failed', 'Stopped')) {
            Remove-Job -Job $lookupJobs[$i] -Force -ErrorAction SilentlyContinue
            $lookupJobs.RemoveAt($i)
        }
    }

    # Sweep responses a parent abandoned (e.g. it timed out and moved on).
    Get-ChildItem -Path $ExchangeDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(partial|result)-' -and
            $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 150
}

foreach ($j in $lookupJobs) { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue }
if ($script:HeartbeatJob) { Remove-Job -Job $script:HeartbeatJob -Force -ErrorAction SilentlyContinue }
