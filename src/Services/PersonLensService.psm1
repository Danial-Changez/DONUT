using module "..\Core\ElevationContext.psm1"
using module "..\Core\LogService.psm1"
using module "..\Core\DonutPaths.psm1"
using module "..\Core\WorkerProcess.psm1"
using module "..\Models\PersonLens.psm1"

<#
.SYNOPSIS
    Resolves a person to a PersonLens (directory facts + devices + BitLocker) through
    a persistent de-elevated agent running as the interactive user.

.DESCRIPTION
    DONUT runs elevated as the admin account, but the Lens data (SCCM affinity +
    BitLocker) is readable only by the operator's regular account - so a single
    LensAgent.ps1 runs DE-ELEVATED for the app's lifetime via a scheduled task and
    serves lookups over an ACL-locked, AES-256-encrypted request/response exchange
    under %ProgramData%\DONUT\lens-agent. This class is the agent's supervisor +
    client: start/heartbeat/restart, drive one lookup, stream partials, teardown.

    See docs/development/architecture/user-lens.md for the full exchange protocol,
    security model, and rationale.

.NOTES
    Mirrors ActiveDirectoryService's seam pattern: the agent/task I/O is isolated in
    the overridable RunLookupJson seam so the parse wiring is unit-testable off a
    domain by subclassing and faking it. LensLookupWorker.ps1 is the pool wrapper
    (-WarmOnly starts the agent at app startup without running a lookup).
#>
class PersonLensService {
    [LogService] $Logger
    [string]     $SiteServer
    [string]     $SourceRoot
    [string]     $SamHint = ''    # Finder-supplied SAM so SCCM affinity can start early.
    [int]        $TimeoutSec = 60

    PersonLensService([string]$siteServer, [string]$sourceRoot) {
        $this.SiteServer = $siteServer
        $this.SourceRoot = $sourceRoot
        $this.Logger = [NullLogService]::new()
    }

    PersonLensService([string]$siteServer, [string]$sourceRoot, [LogService]$logger) {
        $this.SiteServer = $siteServer
        $this.SourceRoot = $sourceRoot
        $this.Logger = [LogService]::Coalesce($logger)
    }

    # Resolves a person to a typed PersonLens. Testable by faking RunLookupJson.
    [PersonLens] Lookup([string]$identity) {
        return [PersonLens]::FromJson($this.RunLookupJson($identity))
    }

    # A parseable error bundle so the UI shows a reason instead of hanging.
    hidden static [string] ErrorBundle([string]$message) {
        return (@{ errors = @($message) } | ConvertTo-Json -Compress)
    }

    # --- Exchange crypto + hygiene (pure; format shared with LensAgent.ps1) ---

    # 48 random bytes per agent session: 32-byte AES-256 key + 16-byte IV.
    static [byte[]] NewKeyIv() {
        $b = [byte[]]::new(48)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($b) } finally { $rng.Dispose() }
        return $b
    }

    # AES-256-CBC (PKCS7) over the UTF-8 text, the twin of the agent's Protect-Text.
    # Kept here so the round trip is unit-testable.
    static [byte[]] ProtectText([string]$text, [byte[]]$keyIv) {
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = [byte[]]($keyIv[0..31]); $aes.IV = [byte[]]($keyIv[32..47])
            $enc = $aes.CreateEncryptor()
            $plain = [System.Text.Encoding]::UTF8.GetBytes($text)
            return $enc.TransformFinalBlock($plain, 0, $plain.Length)
        }
        finally { $aes.Dispose() }
    }

    static [string] UnprotectText([byte[]]$blob, [byte[]]$keyIv) {
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = [byte[]]($keyIv[0..31]); $aes.IV = [byte[]]($keyIv[32..47])
            $dec = $aes.CreateDecryptor()
            return [System.Text.Encoding]::UTF8.GetString(
                $dec.TransformFinalBlock($blob, 0, $blob.Length))
        }
        finally { $aes.Dispose() }
    }

    # Encrypted atomic write (tmp + rename), so the agent never reads a half-written file.
    hidden static [void] WriteEncrypted([string]$path, [string]$text, [byte[]]$keyIv) {
        $tmp = "$path.tmp"
        [IO.File]::WriteAllBytes($tmp, [PersonLensService]::ProtectText($text, $keyIv))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }

    # The exchange dir and task name are fixed so any pool runspace finds the same live
    # agent. Concurrency is serialized by the EnsureAgent mutex.
    static [string] AgentDir() { return (Join-Path $env:ProgramData 'DONUT\lens-agent') }
    static [string] $AgentTaskName = 'DONUT-LensAgent'

    # Two straight lookup timeouts mean a poisoned agent that still beats (dead binds
    # after sleep), so EnsureAgent recycles it. File state outlives per-call services.
    hidden static [string] TimeoutsPath([string]$dir) { return (Join-Path $dir 'timeouts.txt') }

    hidden static [int] ReadLensTimeoutCount([string]$dir) {
        $n = 0
        try {
            $raw = [IO.File]::ReadAllText([PersonLensService]::TimeoutsPath($dir)).Trim()
            if (-not [int]::TryParse($raw, [ref]$n)) { $n = 0 }
        }
        catch { $n = 0 }
        return $n
    }

    hidden static [void] RecordLensTimeout([string]$dir) {
        try {
            $n = [PersonLensService]::ReadLensTimeoutCount($dir) + 1
            [IO.File]::WriteAllText([PersonLensService]::TimeoutsPath($dir), "$n")
        }
        catch { }
    }

    hidden static [void] ClearLensTimeouts([string]$dir) {
        try { [IO.File]::Delete([PersonLensService]::TimeoutsPath($dir)) } catch { }
    }

    hidden static [bool] ShouldForceRecycle([string]$dir) {
        return [PersonLensService]::ReadLensTimeoutCount($dir) -ge 2
    }

    # Full parent-side teardown on close. The purge deletes every lens-* dir because
    # bundles hold BitLocker keys and nothing may outlive the app. Best effort.
    static [void] StopAndPurgeAgent() {
        $dir = [PersonLensService]::AgentDir()
        try { New-Item -ItemType File -Path (Join-Path $dir 'stop.flag') -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { Stop-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -ErrorAction SilentlyContinue } catch { }
        try { Unregister-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        try {
            Get-ChildItem -Path (Split-Path $dir -Parent) -Directory -Filter 'lens-*' -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        catch { }
    }

    # --- Agent supervision ---

    # (Re)starts the agent when its heartbeat is stale, returning '' or a failure reason.
    # Mutex-guarded so concurrent pool runspaces cannot race a double start.
    [string] EnsureAgent() {
        $mutex = [System.Threading.Mutex]::new($false, 'Local\DonutLensAgentInit')
        $owned = $false
        try {
            try { $owned = $mutex.WaitOne(20000) }
            catch [System.Threading.AbandonedMutexException] { $owned = $true }

            $dir = [PersonLensService]::AgentDir()
            $beat = Join-Path $dir 'heartbeat.txt'
            # A beating agent can still be poisoned, and two straight timeouts overrule it.
            $forceRecycle = [PersonLensService]::ShouldForceRecycle($dir)
            if (-not $forceRecycle -and
                (Test-Path -LiteralPath (Join-Path $dir 'key.bin')) -and
                (Test-Path -LiteralPath $beat)) {
                # The agent beats every 2s or so, so anything older means it is gone.
                $beatAge = (Get-Date) - (Get-Item -LiteralPath $beat).LastWriteTime
                if ($beatAge.TotalSeconds -lt 15) { return '' }
            }
            if ($forceRecycle) { $this.Logger.LogWarning('Two Lens lookups timed out in a row, so the agent is being recycled.') }

            $agentScript = Join-Path $this.SourceRoot 'Scripts\LensAgent.ps1'
            if (-not (Test-Path -LiteralPath $agentScript)) { return "LensAgent.ps1 not found at $agentScript" }

            $interactiveUser = [ElevationContext]::InteractiveUser()
            if (-not $interactiveUser) { return 'no interactive desktop session to de-elevate into.' }

            # Cold start: replace any previous instance and rebuild the exchange dir.
            $taskName = [PersonLensService]::AgentTaskName
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            # ProgramData grants every local user read, and bundles hold BitLocker keys.
            $aclError = [DonutPaths]::Secure($dir)
            if ($aclError) { return $aclError }

            # Session key: the agent encrypts every payload with it for its lifetime.
            [IO.File]::WriteAllBytes((Join-Path $dir 'key.bin'), [PersonLensService]::NewKeyIv())

            $pwshPath = [WorkerProcess]::FindPwsh()
            if (-not $pwshPath) { return 'could not resolve pwsh.exe to run the de-elevated agent.' }

            $donutPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
            $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ExchangeDir "{1}" -ParentPid {2} -SiteServer "{3}"' -f $agentScript, $dir, $donutPid, $this.SiteServer
            # -WindowStyle Hidden applies too late to stop the flash, so conhost runs it.
            $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
            $action =
            if (Test-Path -LiteralPath $conhost) {
                $headless = '--headless "{0}" {1}' -f $pwshPath, $argline
                New-ScheduledTaskAction -Execute $conhost -Argument $headless
            }
            else {
                New-ScheduledTaskAction -Execute $pwshPath -Argument $argline
            }
            $principalArgs = @{ UserId = $interactiveUser; LogonType = 'Interactive'; RunLevel = 'Limited' }
            $principal = New-ScheduledTaskPrincipal @principalArgs
            # No execution time limit: the agent lives until its -ParentPid watchdog fires.
            $taskSettings = @{
                AllowStartIfOnBatteries    = $true
                DontStopIfGoingOnBatteries = $true
                StartWhenAvailable         = $true
                ExecutionTimeLimit         = (New-TimeSpan -Seconds 0)
                MultipleInstances          = 'IgnoreNew'
            }
            $settings = New-ScheduledTaskSettingsSet @taskSettings
            $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
            Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop |
                Out-Null
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

            # Wait for the first heartbeat (the agent writes it before its pre-warm).
            $deadline = (Get-Date).AddSeconds(20)
            while ((Get-Date) -lt $deadline) {
                if (Test-Path -LiteralPath $beat) { return '' }
                Start-Sleep -Milliseconds 200
            }
            return "the agent did not start within 20s (as $interactiveUser)."
        }
        catch {
            return "could not start the Lens agent: $($_.Exception.Message)"
        }
        finally {
            if ($owned) { try { $mutex.ReleaseMutex() } catch { } }
            $mutex.Dispose()
        }
    }

    # Shared in-process path: loads the Lens helpers and runs one resolver as the
    # current de-elevated user. $bundleErrors wraps failures as parseable bundles.
    hidden [string] RunInProcess([string]$label, [bool]$bundleErrors,
        [string]$resolver, [hashtable]$resolverArgs) {
        try {
            $common = Join-Path $this.SourceRoot 'Scripts\LensAgent.Common.ps1'
            if (-not (Test-Path -LiteralPath $common)) {
                if ($bundleErrors) { return [PersonLensService]::ErrorBundle("Lens helpers not found at $common") }
                return ''
            }
            . $common
            $script:ForestNc = Get-LensForestNc
            return [string](& $resolver @resolverArgs)
        }
        catch {
            $this.Logger.LogException("In-process $label failed", $_)
            if ($bundleErrors) { return [PersonLensService]::ErrorBundle("Lens lookup failed: $($_.Exception.Message)") }
            return ''
        }
    }

    # The same lookup the agent runs, called here instead of handed across the exchange.
    # No partials: the pane fills in one step rather than progressively.
    hidden [string] RunLookupInProcess([string]$identity) {
        return $this.RunInProcess("Lens lookup for $identity", $true, 'Resolve-Lens',
            @{ identity = $identity; samHint = $this.SamHint; server = $this.SiteServer; reqId = '' })
    }

    # --- Env-coupled seam (overridden in tests) ---

    # Machine list to SCCM primary users, as @{ owners = @(...), error } JSON. One request
    # covers the whole list, which the agent resolves back to back rather than one each.
    [string] RunOwnerLookupJson([string[]]$machines) {
        if (@($machines).Count -eq 0) { return '' }
        if (-not [ElevationContext]::IsElevated()) {
            return $this.RunInProcess('owner lookup', $false, 'Resolve-MachineOwnerBatch',
                @{ wsids = @($machines); server = $this.SiteServer })
        }
        return $this.ExchangeRoundTrip(
            @{ kind = 'owner'; machines = @($machines); siteServer = $this.SiteServer }, $false)
    }

    # User to their application deployments, as @{ deployments = @(...), error } JSON.
    # Dispatched in parallel with the person lookup, so neither ever waits on the other.
    [string] RunSoftwareLookupJson([string]$identity) {
        if ([string]::IsNullOrWhiteSpace($identity)) { return '' }
        if (-not [ElevationContext]::IsElevated()) {
            return $this.RunInProcess('software lookup', $false, 'Resolve-UserSoftware',
                @{ identity = $identity; sam = $this.SamHint; server = $this.SiteServer })
        }
        return $this.ExchangeRoundTrip(
            @{ kind = 'software'; identity = $identity; sam = $this.SamHint
                siteServer = $this.SiteServer
            }, $false)
    }

    [string] RunLookupJson([string]$identity) {
        # De-elevated, DONUT is already the user whose rights this data needs.
        if (-not [ElevationContext]::IsElevated()) { return $this.RunLookupInProcess($identity) }

        return $this.ExchangeRoundTrip(
            @{ identity = $identity; sam = $this.SamHint; siteServer = $this.SiteServer }, $true)
    }

    # The encrypted round trip both lookups share: write request-<id>, wait for
    # result-<id>, return its decrypted text. Only person lookups stream partial-<id>-N.
    hidden [string] ExchangeRoundTrip([hashtable]$request, [bool]$streamPartials) {
        $agentErr = $this.EnsureAgent()
        if ($agentErr) { return [PersonLensService]::ErrorBundle("Lens agent unavailable: $agentErr") }

        $dir = [PersonLensService]::AgentDir()
        $keyIv = $null
        try { $keyIv = [IO.File]::ReadAllBytes((Join-Path $dir 'key.bin')) } catch { }
        if (-not $keyIv -or $keyIv.Length -ne 48) { return [PersonLensService]::ErrorBundle('Lens agent session key is missing - retry the lookup.') }

        $reqId = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $resultPath = Join-Path $dir "result-$reqId.bin"
        try {
            [PersonLensService]::WriteEncrypted((Join-Path $dir "request-$reqId.bin"),
                ($request | ConvertTo-Json -Compress), $keyIv)

            # Writes are atomic (tmp + rename), but a scanner can hold a fresh file briefly.
            $deadline = (Get-Date).AddSeconds($this.TimeoutSec)
            $partialIndex = 1
            $warnedIndex = 0
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
                $partialPath = Join-Path $dir ("partial-{0}-{1}.bin" -f $reqId, $partialIndex)
                if ($streamPartials -and (Test-Path -LiteralPath $partialPath)) {
                    try {
                        $partialText = [PersonLensService]::UnprotectText(
                            [IO.File]::ReadAllBytes($partialPath), $keyIv)
                        Write-Information -MessageData $partialText -Tags 'LensPartial'
                        $partialIndex++
                        continue   # Check for the next partial before sleeping.
                    }
                    catch {
                        # The index holds so the next tick retries instead of skipping.
                        if ($warnedIndex -ne $partialIndex) {
                            $warnedIndex = $partialIndex
                            $this.Logger.LogWarning("Lens partial $partialIndex is locked or torn, retrying.")
                        }
                    }
                }
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $resultPath)) {
                # Strikes accumulate across service instances until a lookup lands.
                [PersonLensService]::RecordLensTimeout($dir)
                return [PersonLensService]::ErrorBundle("The lens lookup did not complete within $($this.TimeoutSec)s (agent heartbeat may have died mid-lookup - retry).")
            }
            [PersonLensService]::ClearLensTimeouts($dir)
            # A scanner can hold the fresh result briefly, so the read gets a few tries.
            $resultText = ''
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    $resultText = [PersonLensService]::UnprotectText(
                        [IO.File]::ReadAllBytes($resultPath), $keyIv)
                    break
                }
                catch {
                    if ($attempt -eq 5) { throw }
                    Start-Sleep -Milliseconds 100
                }
            }
            return $resultText
        }
        catch {
            return [PersonLensService]::ErrorBundle("Lens lookup failed: $($_.Exception.Message)")
        }
        finally {
            # Consume this lookup's files, and the agent's 10-minute sweep covers the rest.
            Get-ChildItem -Path $dir -Filter "*-$reqId*.bin" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}
