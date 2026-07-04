using module "..\Core\LogService.psm1"
using module "..\Models\PersonLens.psm1"

<#
.SYNOPSIS
    Resolves a person to a PersonLens (directory facts + devices + BitLocker) through
    a persistent de-elevated agent running as the interactive user.

.DESCRIPTION
    DONUT runs elevated as the admin account, but the Lens data (SCCM affinity +
    BitLocker) is readable only by the operator's regular account. A single
    LensAgent.ps1 runs DE-ELEVATED for the app's lifetime - started at app startup
    (or restarted on demand when its heartbeat goes stale) via a scheduled task
    (Interactive logon = the logged-on token, no password; RunLevel Limited;
    conhost --headless so no console window ever appears). Persistence removes the
    per-pick task registration + pwsh cold start, and the agent pre-warms its
    libraries in parallel with DONUT's own startup.

    Lookups are a request/response exchange over the fixed, ACL-locked
    %ProgramData%\DONUT\lens-agent dir (inherited ACL stripped to SYSTEM /
    Administrators / the interactive user): the parent writes request-<id>.bin, the
    agent answers partial-<id>-1 (directory facts), partial-<id>-2 (name-only device
    rows) and result-<id>.bin. Because bundles hold BitLocker recovery keys, every
    payload is AES-256 encrypted with the session key (key.bin, minted at agent
    start); partials are streamed to the caller on the Information stream (tag
    'LensPartial'). The agent exits when DONUT's process dies or stop.flag appears;
    the window-close purge stops/unregisters the task and deletes the dir.

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
    [string]     $SamHint = ''    # finder-supplied SAM so the agent can start SCCM affinity early
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

    # --- exchange crypto + hygiene (pure; format shared with LensAgent.ps1) ---------

    # 48 random bytes per agent session: 32-byte AES-256 key + 16-byte IV.
    static [byte[]] NewKeyIv() {
        $b = [byte[]]::new(48)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($b) } finally { $rng.Dispose() }
        return $b
    }

    # AES-256-CBC (PKCS7) over the UTF-8 text - the twin of the agent's Protect-Text;
    # kept here so the round-trip is unit-testable.
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
            return [System.Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($blob, 0, $blob.Length))
        }
        finally { $aes.Dispose() }
    }

    # Encrypted atomic write (tmp + rename), so the agent never reads a half-written file.
    hidden static [void] WriteEncrypted([string]$path, [string]$text, [byte[]]$keyIv) {
        $tmp = "$path.tmp"
        [IO.File]::WriteAllBytes($tmp, [PersonLensService]::ProtectText($text, $keyIv))
        Move-Item -LiteralPath $tmp -Destination $path -Force
    }

    # The agent's fixed exchange dir + task name (fixed so any pool runspace finds the
    # same live agent; concurrency is serialized by the EnsureAgent mutex).
    static [string] AgentDir() { return (Join-Path $env:ProgramData 'DONUT\lens-agent') }
    static [string] $AgentTaskName = 'DONUT-LensAgent'

    # Deletes per-lookup lens-* dirs older than $minutes left by PREVIOUS builds or
    # crashes - never the live agent's own dir, which EnsureAgent manages itself.
    static [void] SweepStaleExchanges([int]$minutes) {
        $root = Join-Path $env:ProgramData 'DONUT'
        Get-ChildItem -Path $root -Directory -Filter 'lens-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'lens-agent' -and $_.LastWriteTime -lt (Get-Date).AddMinutes(-$minutes) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Full parent-side teardown on app close: stop.flag makes the agent exit now,
    # stop/unregister removes the task, and the purge deletes every lens-* dir (bundles
    # can hold BitLocker keys - nothing may outlive the app). All best-effort; keeps
    # every parent-side literal in this one class.
    static [void] StopAndPurgeAgent() {
        $dir = [PersonLensService]::AgentDir()
        try { New-Item -ItemType File -Path (Join-Path $dir 'stop.flag') -Force -ErrorAction SilentlyContinue | Out-Null } catch { }
        try { Stop-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -ErrorAction SilentlyContinue } catch { }
        try { Unregister-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        try {
            Get-ChildItem -Path (Split-Path $dir -Parent) -Directory -Filter 'lens-*' -ErrorAction SilentlyContinue |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        } catch { }
    }

    # --- agent supervision -------------------------------------------------------

    # Ensures the persistent de-elevated agent is alive, (re)starting it when the
    # heartbeat is stale. Returns '' on success or the failure reason. Mutex-guarded
    # so concurrent pool runspaces can't race a double start.
    [string] EnsureAgent() {
        $mutex = [System.Threading.Mutex]::new($false, 'Local\DonutLensAgentInit')
        $owned = $false
        try {
            try { $owned = $mutex.WaitOne(20000) } catch [System.Threading.AbandonedMutexException] { $owned = $true }

            $dir = [PersonLensService]::AgentDir()
            $beat = Join-Path $dir 'heartbeat.txt'
            if ((Test-Path -LiteralPath (Join-Path $dir 'key.bin')) -and (Test-Path -LiteralPath $beat)) {
                # The agent beats every ~2s; anything older means it's gone.
                if (((Get-Date) - (Get-Item -LiteralPath $beat).LastWriteTime).TotalSeconds -lt 15) { return '' }
            }

            $agentScript = Join-Path $this.SourceRoot 'Scripts\LensAgent.ps1'
            if (-not (Test-Path -LiteralPath $agentScript)) { return "LensAgent.ps1 not found at $agentScript" }

            $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $explorer) { return 'no interactive desktop session to de-elevate into.' }
            $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
            $interactiveUser = "$($owner.Domain)\$($owner.User)"

            # Cold start: replace any previous instance and rebuild the exchange dir.
            [PersonLensService]::SweepStaleExchanges(15)
            Stop-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -ItemType Directory -Path $dir -Force | Out-Null

            # Strip the inherited ACL (ProgramData grants all local users read!) down to
            # SYSTEM / Administrators / the interactive user - bundles hold BitLocker keys.
            try {
                $acl = Get-Acl $dir
                $acl.SetAccessRuleProtection($true, $false)
                $system = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
                $admins = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($interactiveUser, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                Set-Acl -Path $dir -AclObject $acl
            }
            catch {
                return "could not secure the exchange folder for ${interactiveUser}: $($_.Exception.Message)"
            }

            # Session key: the agent encrypts every payload with it for its lifetime.
            [IO.File]::WriteAllBytes((Join-Path $dir 'key.bin'), [PersonLensService]::NewKeyIv())

            # Resolve pwsh.exe via PATH: $PID isn't accessible in a class method, and the
            # production host is Donut.Launcher.exe anyway. PowerShell 7 is a prerequisite.
            $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
            $pwshPath = if ($cmd) { [string]$cmd.Source } else { '' }
            if (-not $pwshPath) { return 'could not resolve pwsh.exe to run the de-elevated agent.' }

            $donutPid = [System.Diagnostics.Process]::GetCurrentProcess().Id
            $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ExchangeDir "{1}" -ParentPid {2} -SiteServer "{3}"' -f $agentScript, $dir, $donutPid, $this.SiteServer
            # pwsh is a console app: its window is created BEFORE -WindowStyle Hidden can
            # hide it, so an interactive-token task flashes a console on the desktop.
            # conhost --headless runs it on a pseudoconsole with no window at all.
            $conhost = Join-Path $env:WINDIR 'System32\conhost.exe'
            $action =
                if (Test-Path -LiteralPath $conhost) {
                    New-ScheduledTaskAction -Execute $conhost -Argument ('--headless "{0}" {1}' -f $pwshPath, $argline)
                }
                else {
                    New-ScheduledTaskAction -Execute $pwshPath -Argument $argline
                }
            $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
            # PT0S = no execution time limit: the agent lives for the app's lifetime and
            # exits itself when DONUT's process dies (its -ParentPid watchdog).
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew
            $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
            Register-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -InputObject $task -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName ([PersonLensService]::AgentTaskName) -ErrorAction Stop

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

    # --- env-coupled seam (overridden in tests) ---------------------------------

    # One lookup over the agent exchange: write request-<id>, stream partial-<id>-N to
    # the Information stream (tag 'LensPartial'), return the decrypted final bundle.
    [string] RunLookupJson([string]$identity) {
        $agentErr = $this.EnsureAgent()
        if ($agentErr) { return [PersonLensService]::ErrorBundle("Lens agent unavailable: $agentErr") }

        $dir = [PersonLensService]::AgentDir()
        $keyIv = $null
        try { $keyIv = [IO.File]::ReadAllBytes((Join-Path $dir 'key.bin')) } catch { }
        if (-not $keyIv -or $keyIv.Length -ne 48) { return [PersonLensService]::ErrorBundle('Lens agent session key is missing - retry the lookup.') }

        $reqId = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $resultPath = Join-Path $dir "result-$reqId.bin"
        try {
            $request = @{ identity = $identity; sam = $this.SamHint; siteServer = $this.SiteServer } | ConvertTo-Json -Compress
            [PersonLensService]::WriteEncrypted((Join-Path $dir "request-$reqId.bin"), $request, $keyIv)

            # 100ms poll; the agent's writes are atomic (tmp + rename), so no settle wait.
            $deadline = (Get-Date).AddSeconds($this.TimeoutSec)
            $partialIndex = 1
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
                $partialPath = Join-Path $dir ("partial-{0}-{1}.bin" -f $reqId, $partialIndex)
                if (Test-Path -LiteralPath $partialPath) {
                    $partialIndex++
                    try {
                        Write-Information -MessageData ([PersonLensService]::UnprotectText([IO.File]::ReadAllBytes($partialPath), $keyIv)) -Tags 'LensPartial'
                    }
                    catch { }
                    continue   # check for the next partial before sleeping
                }
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $resultPath)) {
                return [PersonLensService]::ErrorBundle("The lens lookup did not complete within $($this.TimeoutSec)s (agent heartbeat may have died mid-lookup - retry).")
            }
            return [PersonLensService]::UnprotectText([IO.File]::ReadAllBytes($resultPath), $keyIv)
        }
        catch {
            return [PersonLensService]::ErrorBundle("Lens lookup failed: $($_.Exception.Message)")
        }
        finally {
            # Consume this lookup's files; the agent + its 10-min sweep cover the rest.
            Get-ChildItem -Path $dir -Filter "*-$reqId*.bin" -File -ErrorAction SilentlyContinue |
                Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}
