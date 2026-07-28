using module '.\AsyncJob.psm1'
using module '.\LogService.psm1'
using module '.\WorkerProcess.psm1'
using module '..\Models\JobEnums.psm1'

<#
.SYNOPSIS
    Fast-lane resolve job: a slim child pwsh spawned directly, off the pool.

.DESCRIPTION
    An AsyncJob whose child is started with Process.Start instead of a pool
    runspace + launcher: no pool slot held for the child's lifetime, no worker
    module graph, no ThreadPool dispatch. Poll() rides the existing PumpJobs
    dispatcher tick and only checks HasExited + reads the small result file, so
    a wedged or slow child can never block the UI thread - and unlike a wedged
    pipeline (which no stop can reach), a wedged process is Kill()-able.

.NOTES
    ProcessFault distinguishes crash/kill/timeout (no verdict produced - the
    coordinator retries on the classic worker path) from a clean DNS "no
    address" verdict, which completes normally with Ip = ''.
#>
class ResolveProcessJob : AsyncJob {
    [System.Diagnostics.Process] $Process
    # True when the child produced no verdict (spawn failure, crash, kill, timeout).
    [bool] $ProcessFault = $false
    [int] $TimeoutSeconds = 30
    hidden [string] $FastResultFile

    ResolveProcessJob([string]$hostName, [JobKind]$type, [LogService]$logger) : base($hostName, $type, $logger) {}

    # Direct spawn: the three args ride the command line (no ArgsFile - RemoteWorker's
    # exists to ship a Settings snapshot this worker never reads).
    [void] Start([string]$scriptPath, [hashtable]$arguments, [string]$tempConfigPath) {
        try {
            $this.FastResultFile = [System.IO.Path]::GetTempFileName()
            # Never ProcessPath directly: launcher-hosted runs would fork a second
            # DONUT that exits 0 with no verdict (see WorkerProcess.FindPwsh).
            $pwsh = [WorkerProcess]::FindPwsh()
            if ([string]::IsNullOrWhiteSpace($pwsh)) {
                throw 'pwsh.exe was not found on PATH - the fast resolve child cannot run.'
            }

            $psi = [System.Diagnostics.ProcessStartInfo]::new($pwsh)
            foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-File', $scriptPath,
                    '-HostName', [string]$arguments.HostName, '-Dc', [string]$arguments.Dc,
                    '-LogsDir', [string]$arguments.LogsDir, '-ResultFile', $this.FastResultFile)) {
                $psi.ArgumentList.Add($a)
            }
            if ([bool]$arguments.DebugLog) { $psi.ArgumentList.Add('-DebugLog') }
            # NO stream redirection: undrained pipes wedge children; the verdict rides
            # the result file and diagnostics ride Donut.log.
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true

            $this.Status = [JobStatus]::Running
            $this.StartedAtUtc = [datetime]::UtcNow
            $this.Process = [System.Diagnostics.Process]::Start($psi)
            $this.Logger.LogDebug(
                "[$($this.HostName)] Started fast Resolve child (pid $($this.Process.Id), no pool slot).")
        }
        catch {
            $this.Status = [JobStatus]::Failed
            $this.ProcessFault = $true
            $this.FailureMessage = $_.Exception.Message
            $this.Logger.LogException("[$($this.HostName)] Fast resolve child failed to start", $_)
        }
    }

    # Non-blocking on the dispatcher: HasExited, then one small file read at exit.
    [void] Poll() {
        if ($this.Status -ne [JobStatus]::Running) { return }

        if (-not $this.Process.HasExited) {
            if (([datetime]::UtcNow - $this.StartedAtUtc).TotalSeconds -ge $this.TimeoutSeconds) {
                $this.KillChild("timed out after $($this.TimeoutSeconds)s")
            }
            return
        }

        try {
            $json = ''
            if (Test-Path -LiteralPath $this.FastResultFile) {
                $json = [string](Get-Content -LiteralPath $this.FastResultFile -Raw)
            }
            if (-not [string]::IsNullOrWhiteSpace($json)) {
                $this.Result = $json | ConvertFrom-Json -AsHashtable
                $this.Status = [JobStatus]::Completed
                $this.Logger.LogDebug("[$($this.HostName)] Fast resolve completed (exit $($this.Process.ExitCode)).")
            }
            else {
                # Exited without a verdict: crash or infrastructure fault in the child.
                $this.Fault("fast resolve child exited $($this.Process.ExitCode) with no verdict (see Donut.log)")
            }
        }
        catch {
            $this.Fault("fast resolve result unreadable: $($_.Exception.Message)")
        }
    }

    hidden [void] Fault([string]$message) {
        $this.Status = [JobStatus]::Failed
        $this.ProcessFault = $true
        $this.FailureMessage = $message
        $this.Logger.LogWarning("[$($this.HostName)] $message")
    }

    # A wedged process - unlike a wedged pipeline - has a clean recovery: Kill.
    hidden [void] KillChild([string]$why) {
        try { $this.Process.Kill($true) }
        catch { $this.Logger.LogDebug("[$($this.HostName)] fast resolve kill failed: $($_.Exception.Message)") }
        $this.Fault("fast resolve $why")
    }

    [void] Cleanup() {
        if ($this.Process) {
            try {
                if (-not $this.Process.HasExited) { $this.Process.Kill($true) }
                $this.Process.Dispose()
            }
            catch { $this.Logger.LogDebug("[$($this.HostName)] fast resolve cleanup: $($_.Exception.Message)") }
        }
        if ($this.FastResultFile -and (Test-Path -LiteralPath $this.FastResultFile)) {
            Remove-Item -LiteralPath $this.FastResultFile -Force -ErrorAction SilentlyContinue
        }
    }
}
