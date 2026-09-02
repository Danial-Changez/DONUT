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
    pre-warms its libraries (GC and home-domain binds, the AdminService affinity and
    hardware routes) on a thread job in parallel with DONUT's own startup, and reuses
    those warm connections for every later lookup. (The finder's AD search is separate - it runs
    in-process on the pool via AdSearchWorker, not through this agent.)

    Protocol over the ACL-locked exchange dir (every payload AES-256-CBC with the
    session key.bin; writes atomic tmp+rename):
      request-<id>.bin    <- { identity, sam, dn, domains, siteServer }   (parent writes)
      partial-<id>-N.bin  -> cumulative bundle snapshots in completion order
                             (directory facts and name-only device rows as each
                             lands, then AD-detailed rows, hardware still pending)
      result-<id>.bin     -> lookup bundle
    The agent deletes each request once read; an unreadable one (a scanner holding
    the fresh file, or a key rotated under a surviving instance) retries for ~2s,
    re-adopts key.bin from disk, and as a last resort answers with an error bundle so
    the parent fails fast instead of waiting out its timeout. The parent deletes the
    responses it consumed; anything older than 10 minutes is swept as abandoned. Two extras ride
    the same dir: warm.flag (plain, parent drops it on resume or a network change,
    the loop answers with an immediate keep-warm ping) and kind='toast' requests
    (key job outcomes raised as Action Center toasts here, because only the
    interactive user's toasts reach the operator's shell).

    A lookup takes tens of seconds, so every request (person lookups, owner batches
    and software lists alike) runs on a ThreadJob and the serve loop stays free to
    accept the next one.
    The lookup pipeline and all exchange helpers live in LensAgent.Common.ps1,
    dot-sourced here and into each request ThreadJob.

    Exits when stop.flag appears, the parent process dies, the exchange dir is
    deleted, or agent.pid (this instance's startup claim on the dir) is gone or names
    another process - the recycle path wipes and rebuilds the dir faster than the
    loop's dir check can notice, and the lost claim is what tells a superseded
    instance to stand down instead of eating requests with a stale session key.
    heartbeat.txt is touched every ~2s by the serve loop itself, which never
    blocks (requests and the pre-warm all ride ThreadJobs), so a fresh beat proves
    requests are being read. A dead or wedged loop stops beating either way, and
    EnsureAgent's 15s staleness check then recycles the agent on the next lookup.

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
$warmFlagPath = Join-Path $ExchangeDir 'warm.flag'
try { [IO.File]::WriteAllText($heartbeatPath, [datetime]::UtcNow.ToString('o')) } catch { return }

# The pid claim marks this dir's one agent: a wipe or a newer claimant tells a superseded instance to exit.
$pidPath = Join-Path $ExchangeDir 'agent.pid'
try { [IO.File]::WriteAllText($pidPath, "$PID") } catch { return }

try { Import-Module ThreadJob -ErrorAction SilentlyContinue } catch { }

# Warming off the loop lets serving start at once, and ThrottleLimit lifts the job cap.
$script:ForestNc = ''
$script:WarmJob = $null
$warmStarted = [datetime]::UtcNow
try {
    $script:WarmJob = Start-ThreadJob -ThrottleLimit 16 `
                                      -ScriptBlock {
        param($commonPath, $siteServer)
        . $commonPath
        $nc = ''
        # Blank on failure is the handled case: request jobs retry the read themselves.
        try { $nc = Get-LensForestNc } catch { $nc = '' }
        $script:ForestNc = $nc
        # Bind the GC once so later lookups reuse the warm connection.
        try { $null = Find-Gc '(objectClass=domain)' } catch { }
        # A person shaped read warms the index the first real pick will use.
        $warmUser = '(&(objectCategory=person)(objectClass=user)(sAMAccountName=zzz-donut-warm))'
        try { $null = Find-Gc $warmUser } catch { }
        # A base read on the domain head warms the plain LDAP bind the first pick pays.
        try {
            $dnc = [string]([ADSI]'LDAP://RootDSE').Properties['defaultNamingContext'][0]
            $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$dnc")
            $ds.SearchScope = 'Base'
            $ds.Filter = '(objectClass=*)'
            $ds.ClientTimeout = [TimeSpan]::FromSeconds(5)
            $null = $ds.FindOne()
        } catch { }
        if ($siteServer) {
            # Throwaway affinity primes TLS + Kerberos to the AdminService (result discarded).
            try { $null = & $script:AffinityScript $siteServer 'zzz-donut-warm' } catch { }
            # A throwaway inventory read wakes the hardware route on the site server too.
            $pair = @{ name = 'zzz-donut-warm'; resourceId = '0' }
            try { $null = & $script:HardwareScript $siteServer $pair } catch { }
            # One SMS_R_User miss warms the software route's first hop as well.
            try { $null = & $script:SoftwareScript $siteServer 'zzz-donut-warm' } catch { }
        }
        return $nc
    } -ArgumentList $commonPath, $SiteServer
} catch { $script:WarmJob = $null }

# --- Serve loop ---
# Nothing here may touch the network, so a fresh beat proves the loop is serving.
$lookupJobs = [System.Collections.Generic.List[object]]::new()
$reqRetries = @{}   # request id -> failed read attempts, see the retry note below
$lastBeat = [datetime]::MinValue
$lastParentCheck = [datetime]::MinValue
$lastWarmPing = [datetime]::UtcNow   # the startup warm above just covered this slot
while ($true) {
    if (Test-Path -LiteralPath $stopPath) { break }
    # Dir purged out from under us -> exit.
    if (-not (Test-Path -LiteralPath $ExchangeDir)) { break }

    $now = [datetime]::UtcNow
    if (($now - $lastBeat).TotalSeconds -ge 2) {
        $lastBeat = $now
        # The dir check above can miss a wipe-and-rebuild between passes; a lost pid claim says superseded.
        $claim = ''
        try { $claim = [IO.File]::ReadAllText($pidPath).Trim() } catch { }
        if ($claim -ne "$PID") { break }
        try { [IO.File]::WriteAllText($heartbeatPath, $now.ToString('o')) }
        catch { break }   # Exchange dir gone (the parent purged it), so exit.
    }
    if (($now - $lastParentCheck).TotalSeconds -ge 3) {
        $lastParentCheck = $now
        # A missing parent process means DONUT closed.
        if (-not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) {
            # The reason on the flag is the breadcrumb Diagnose-LensAgent reads.
            try { [IO.File]::WriteAllText($stopPath, 'parent-exited') } catch { }
            break
        }
    }

    # Collect the warm result without waiting. A warm stuck past 3 minutes is cut
    # loose, and request jobs then compute the naming context themselves.
    if ($script:WarmJob) {
        if ([string]$script:WarmJob.State -in @('Completed', 'Failed', 'Stopped')) {
            $nc = Receive-Job -Job $script:WarmJob -ErrorAction SilentlyContinue
            if ($nc) { $script:ForestNc = [string]($nc | Select-Object -Last 1) }
            Remove-Job -Job $script:WarmJob -Force -ErrorAction SilentlyContinue
            $script:WarmJob = $null
        } elseif (($now - $warmStarted).TotalMinutes -ge 3) {
            Stop-Job -Job $script:WarmJob -ErrorAction SilentlyContinue
            Remove-Job -Job $script:WarmJob -Force -ErrorAction SilentlyContinue
            $script:WarmJob = $null
        }
    }

    # The parent drops warm.flag on resume or a network change, so the ping runs now.
    if (Test-Path -LiteralPath $warmFlagPath) {
        Remove-Item -LiteralPath $warmFlagPath `
                    -Force `
                    -ErrorAction SilentlyContinue
        $lastWarmPing = [datetime]::MinValue
    }

    # The startup warm decays while DONUT idles and the next pick repays it as
    # seconds, so a cheap ping keeps the AdminService route and the AD binds hot.
    if (($now - $lastWarmPing).TotalMinutes -ge 4) {
        $lastWarmPing = $now
        try {
            $ping = Start-ThreadJob -ThrottleLimit 16 `
                                    -ScriptBlock {
                param($commonPath, $server)
                . $commonPath
                # The GC read walks RootDSE first, evicting any socket that died in sleep.
                try {
                    $script:ForestNc = Get-LensForestNc
                    $null = Find-Gc '(objectClass=domain)'
                } catch { }
                if ($server) { try { $null = & $script:AffinityScript $server 'zzz-donut-warm' } catch { } }
            } -ArgumentList $commonPath, $SiteServer
            $lookupJobs.Add(@{ Job = $ping; Started = [datetime]::UtcNow })
        } catch { }
    }

    $requests = @(Get-ChildItem -Path $ExchangeDir `
                                -Filter 'request-*.bin' `
                                -File `
                                -ErrorAction SilentlyContinue |
            Sort-Object CreationTimeUtc)
    foreach ($reqFile in $requests) {
        $reqId = $reqFile.BaseName -replace '^request-', ''
        $req = $null
        try { $req = Unprotect-File $reqFile.FullName | ConvertFrom-Json }
        catch { }
        if ($null -eq $req) {
            # A held file or a rotated key retries across passes, never drops while the parent waits.
            $tries = [int]$reqRetries[$reqId] + 1
            $reqRetries[$reqId] = $tries
            if ($tries -eq 8) {
                # Adopting a rotated key.bin also heals this agent for every later request.
                try {
                    $disk = [IO.File]::ReadAllBytes((Join-Path $ExchangeDir 'key.bin'))
                    if ($disk.Length -eq 48) { $script:KeyIv = $disk }
                } catch { }
                try { $req = Unprotect-File $reqFile.FullName | ConvertFrom-Json }
                catch { }
            }
            if ($null -eq $req -and $tries -lt 12) { continue }   # left in place to retry
        }
        [void]$reqRetries.Remove($reqId)
        Remove-Item -LiteralPath $reqFile.FullName `
                    -Force `
                    -ErrorAction SilentlyContinue
        if ($null -eq $req) {
            # One bundle both parsers read, so whichever lookup asked fails fast and says why.
            try {
                $reason = 'Lens agent: the request could not be read (a held file, or a rotated session key).'
                $errJson = @{
                    errors      = @($reason)
                    error       = $reason
                    deployments = @()
                    owners      = @()
                } | ConvertTo-Json -Compress
                Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $errJson
            } catch { }
            continue
        }
        try {
            # One launch shape for every request; the job dispatches on $req.kind itself.
            $job = Start-ThreadJob -ThrottleLimit 16 `
                                   -ScriptBlock {
                param($commonPath, $exchangeDir, $keyIv, $forestNc, $req, $reqId)
                Import-Module ThreadJob -ErrorAction SilentlyContinue
                . $commonPath
                $script:KeyIv = $keyIv
                $script:ForestNc = $forestNc
                $ExchangeDir = $exchangeDir
                # The warm may not have landed yet, and one RootDSE read is cheap.
                if (-not $script:ForestNc) { try { $script:ForestNc = Get-LensForestNc } catch { } }
                $server = [string]$req.siteServer
                $resultPath = Join-Path $exchangeDir ("result-{0}.bin" -f $reqId)
                switch ([string]$req.kind) {
                    'owner' {
                        # One batched owner request still beats N single ones through this loop.
                        $json = ''
                        try { $json = Resolve-MachineOwnerBatch -wsids @($req.machines) -server $server }
                        catch {
                            $json = @{ owners = @(); error = "owner batch: $($_.Exception.Message)" } |
                                ConvertTo-Json -Compress
                        }
                        Write-LensBundle $resultPath $json
                    }
                    'software' {
                        # The user's whole software list rides one request, like the owner batch.
                        $json = ''
                        try {
                            $json = Resolve-UserSoftware -identity ([string]$req.identity) `
                                                         -sam ([string]$req.sam) `
                                                         -server $server `
                                                         -dn ([string]$req.dn)
                        } catch {
                            $json = @{ deployments = @(); error = "software: $($_.Exception.Message)" } |
                                ConvertTo-Json -Compress
                        }
                        Write-LensBundle $resultPath $json
                    }
                    'toast' {
                        # Fire and forget: only this identity's toasts reach the operator's shell.
                        try { Show-LensToast -title ([string]$req.title) -body ([string]$req.body) }
                        catch { }
                    }
                    default {
                        Resolve-Lens -identity ([string]$req.identity) `
                                     -samHint ([string]$req.sam) `
                                     -server $server `
                                     -reqId $reqId `
                                     -dn ([string]$req.dn) `
                                     -domains @($req.domains | Where-Object { $_ })
                    }
                }
            } -ArgumentList $commonPath, $ExchangeDir, $script:KeyIv, $script:ForestNc, $req, $reqId
            $lookupJobs.Add(@{ Job = $job; Started = [datetime]::UtcNow })
        } catch {
            # Never leave the parent hanging: always answer, even if only with the error.
            try {
                $errJson = @{ errors = @("Lens agent: $($_.Exception.Message)") } | ConvertTo-Json
                Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $errJson
            } catch { }
        }
    }

    # Reap finished request jobs, and cut loose any stuck past 90 seconds: the parent
    # stops listening at 60, so an older job only hogs a throttle slot.
    for ($i = $lookupJobs.Count - 1; $i -ge 0; $i--) {
        $entry = $lookupJobs[$i]
        $done = [string]$entry.Job.State -in @('Completed', 'Failed', 'Stopped')
        if (-not $done -and ([datetime]::UtcNow - $entry.Started).TotalSeconds -lt 90) { continue }
        if (-not $done) { Stop-Job -Job $entry.Job -ErrorAction SilentlyContinue }
        Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue
        $lookupJobs.RemoveAt($i)
    }

    # A request another instance consumed leaves a stale retry entry, so idle clears them.
    if ($requests.Count -eq 0 -and $reqRetries.Count -gt 0) { $reqRetries.Clear() }

    # Sweep responses a parent abandoned (e.g. it timed out and moved on).
    Get-ChildItem -Path $ExchangeDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(partial|result)-' -and
            $_.LastWriteTimeUtc -lt [datetime]::UtcNow.AddMinutes(-10) } |
        Remove-Item -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 150
}

foreach ($entry in $lookupJobs) {
    Remove-Job -Job $entry.Job `
               -Force `
               -ErrorAction SilentlyContinue
}
if ($script:WarmJob) {
    Remove-Job -Job $script:WarmJob `
               -Force `
               -ErrorAction SilentlyContinue
}
