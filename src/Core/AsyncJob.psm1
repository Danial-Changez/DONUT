using namespace System.Collections.Concurrent
using module '.\RunspaceManager.psm1'
using module '.\LogService.psm1'
using module '.\WorkerProcess.psm1'
using module '..\Models\JobEnums.psm1'
using module '..\Models\LogLine.psm1'

<#
.SYNOPSIS
    A single background remote operation run on the shared runspace pool.

.DESCRIPTION
    Wraps a PowerShell instance bound to the RunspaceManager pool: Start() begins
    RemoteWorker.ps1 asynchronously with the prepared arguments, Poll() drains its
    streamed output into a thread-safe queue and flips Status on completion, and
    Cleanup() disposes the instance. The presenter's PumpJobs loop polls these.
#>
class AsyncJob {
    [System.Management.Automation.PowerShell] $PowerShell
    [string] $HostName
    [JobKind]   $JobType
    [JobStatus] $Status
    [ConcurrentQueue[LogLine]] $Logs
    [object] $Result
    # First error text when Status is Failed (survives the runspace boundary).
    [string] $FailureMessage = ''
    [string] $TempConfigPath
    [System.IAsyncResult] $AsyncResult
    [LogService] $Logger
    # Temp-file handoff to the child: a per-job AppDomain dodges the class-load deadlock.
    hidden [string] $ArgsFilePath
    hidden [string] $ResultFilePath

    # Stall heartbeat: the pool free count separates a starved pool from a wedged worker.
    [datetime] $StartedAtUtc
    hidden [datetime] $NextStallLogUtc
    hidden [int] $StallWarnAfterSeconds = 90
    hidden [int] $StallRepeatSeconds = 300

    # Test convenience only. Production sites must pass the real logger, or job
    # failures leave no trace in Donut.log (AsyncJobLoggerCoverage.Tests enforces).
    AsyncJob([string]$hostName, [JobKind]$type) {
        $this.Initialize($hostName, $type, $null)
    }

    AsyncJob([string]$hostName, [JobKind]$type, [LogService]$logger) {
        $this.Initialize($hostName, $type, $logger)
    }

    hidden [void] Initialize([string]$hostName, [JobKind]$type, [LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.HostName = $hostName
        $this.JobType = $type
        $this.Status = [JobStatus]::Created
        $this.Logs = [ConcurrentQueue[LogLine]]::new()
    }

    [void] Start([string]$scriptPath, [hashtable]$arguments, [string]$tempConfigPath) {
        $this.TempConfigPath = $tempConfigPath

        try {
            # The launcher stays class-free so the pool runspace never deadlocks.
            $prep = [WorkerProcess]::Prepare($scriptPath, $arguments, $tempConfigPath)
            $this.ArgsFilePath = $prep.ArgsFile
            $this.ResultFilePath = $prep.ResultFile

            $pool = [RunspaceManager]::GetPool()
            $this.PowerShell = [System.Management.Automation.PowerShell]::Create()
            $this.PowerShell.RunspacePool = $pool
            $this.PowerShell.AddScript($prep.Launcher) | Out-Null
            $this.PowerShell.AddArgument($prep.PwshPath) | Out-Null
            $this.PowerShell.AddArgument($prep.ScriptPath) | Out-Null
            $this.PowerShell.AddArgument($prep.ArgsFile) | Out-Null
            $this.PowerShell.AddArgument($prep.ResultFile) | Out-Null

            $this.Status = [JobStatus]::Running
            $this.StartedAtUtc = [datetime]::UtcNow
            $this.NextStallLogUtc = $this.StartedAtUtc.AddSeconds($this.StallWarnAfterSeconds)
            $this.AsyncResult = $this.PowerShell.BeginInvoke()
            $this.Logger.LogDebug("[$($this.HostName)] Started $($this.JobType) job (child process).")
        }
        catch {
            $this.Status = [JobStatus]::Failed
            $this.Logger.LogException("[$($this.HostName)] Failed to start $($this.JobType) job", $_)
            $this.Logs.Enqueue([LogLine]::Donut([LogSeverity]::Error, "Exception: $_"))
        }
    }

    [void] Poll() {
        if ($this.Status -ne [JobStatus]::Running) { return }

        if ($this.AsyncResult.IsCompleted) {
            try {
                $verdict = [WorkerProcess]::Interpret($this.PowerShell.EndInvoke($this.AsyncResult))
                $this.Result = $verdict.Result

                if ($this.PowerShell.HadErrors -or -not $verdict.Succeeded) {
                    $this.Status = [JobStatus]::Failed
                    $this.FailureMessage = $verdict.FailureMessage
                    # Left undecorated so RemoteFailure.ReasonFromMessage can still match it.
                    $this.Logs.Enqueue([LogLine]::Donut([LogSeverity]::Error, $this.FailureMessage))
                    $this.Logger.LogError("[$($this.HostName)] $($this.JobType) worker failed " +
                        "(exit $($verdict.ExitCode)): $($this.FailureMessage)")
                }
                else {
                    $this.Status = [JobStatus]::Completed
                    $this.Logger.LogDebug("[$($this.HostName)] $($this.JobType) job completed.")
                }
            }
            catch {
                $this.Status = [JobStatus]::Failed
                $this.FailureMessage = $_.Exception.Message
                $this.Logs.Enqueue([LogLine]::Donut([LogSeverity]::Error, "Exception: $_"))
                $this.Logger.LogException("[$($this.HostName)] $($this.JobType) job failed during completion", $_)
            }
        }
        elseif ($this.NextStallLogUtc -ne [datetime]::MinValue -and
            [datetime]::UtcNow -ge $this.NextStallLogUtc) {
            # MinValue means Start() never armed the heartbeat (test doubles), not a stall.
            $this.LogStallHeartbeat()
        }

        $this.DrainStream($this.PowerShell.Streams.Information, [LogSeverity]::Info)
        $this.DrainStream($this.PowerShell.Streams.Verbose, [LogSeverity]::Info)
        $this.DrainStream($this.PowerShell.Streams.Warning, [LogSeverity]::Warn)
        $this.DrainStream($this.PowerShell.Streams.Error, [LogSeverity]::Error)
    }

    # One WARN per interval while a job neither completes nor fails, so the log says
    # where the time went instead of just going quiet.
    hidden [void] LogStallHeartbeat() {
        $elapsed = [long]([datetime]::UtcNow - $this.StartedAtUtc).TotalSeconds
        $pool = 'unknown'
        $freeRunspaces = -1
        try {
            $p = [RunspaceManager]::GetPool()
            $freeRunspaces = $p.GetAvailableRunspaces()
            $pool = "$freeRunspaces/$($p.GetMaxRunspaces()) free"
        }
        catch {
            $this.Logger.LogDebug(
                "Stall heartbeat: pool state unreadable: $($_.Exception.Message)")
        }
        $state = 'unknown'
        $firstError = ''
        try {
            $state = "$($this.PowerShell.InvocationStateInfo.State)"
            if ($this.PowerShell.Streams.Error.Count -gt 0) {
                $firstError = " firstError=$($this.PowerShell.Streams.Error[0])"
            }
        }
        catch {
            $this.Logger.LogDebug(
                "Stall heartbeat: shell state unreadable: $($_.Exception.Message)")
        }
        # Near-zero free threads with idle runspaces means dispatch itself is starved.
        $tp = 'unknown'
        try {
            $w = 0; $io = 0
            [System.Threading.ThreadPool]::GetAvailableThreads([ref]$w, [ref]$io)
            $tp = "$w worker / $io IOCP free"
        }
        catch {
            $this.Logger.LogDebug(
                "Stall heartbeat: threadpool state unreadable: $($_.Exception.Message)")
        }
        $this.Logger.LogWarning(
            "[$($this.HostName)] $($this.JobType) job still running after $elapsed s " +
            "(pool: $pool, threadpool: $tp, state: $state$firstError). Idle runspaces " +
            "with ~0 free threads means dispatch is starved; otherwise the worker " +
            "itself has not returned.")
        $this.NextStallLogUtc = [datetime]::UtcNow.AddSeconds($this.StallRepeatSeconds)
    }

    # The stream a record arrived on is its severity, which was discarded here before.
    [void] DrainStream($stream, [LogSeverity]$severity) {
        if (-not $stream) { return }
        foreach ($item in $stream.ReadAll()) {
            $this.Logs.Enqueue([LogLine]::FromWorkerLine($item.ToString(), $severity))
        }
    }

    [void] Cleanup() {
        if ($this.PowerShell) { $this.PowerShell.Dispose() }
        foreach ($f in @($this.TempConfigPath, $this.ArgsFilePath, $this.ResultFilePath)) {
            if ($f -and (Test-Path $f)) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
    }
}
