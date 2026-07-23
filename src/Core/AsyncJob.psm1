using namespace System.Collections.Concurrent
using module '.\RunspaceManager.psm1'
using module '.\LogService.psm1'
using module '..\Models\JobEnums.psm1'

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
    [ConcurrentQueue[string]] $Logs
    [object] $Result
    # First error text when Status is Failed (survives the runspace boundary).
    [string] $FailureMessage = ''
    [string] $TempConfigPath
    [System.IAsyncResult] $AsyncResult
    [LogService] $Logger

    # Stall heartbeat: Poll() warns at StallWarnAfterSeconds then every repeat, with
    # the pool free count discriminating queued-behind-starved-pool vs wedged worker.
    [datetime] $StartedAtUtc
    hidden [datetime] $NextStallLogUtc
    hidden [int] $StallWarnAfterSeconds = 90
    hidden [int] $StallRepeatSeconds = 300

    # Test convenience only - production sites must pass the real logger, or job
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
        $this.Logs = [ConcurrentQueue[string]]::new()
    }

    [void] Start([string]$scriptPath, [hashtable]$arguments, [string]$tempConfigPath) {
        $this.TempConfigPath = $tempConfigPath

        try {
            $pool = [RunspaceManager]::GetPool()
            $this.PowerShell = [System.Management.Automation.PowerShell]::Create()
            $this.PowerShell.RunspacePool = $pool
            $this.PowerShell.AddCommand($scriptPath) | Out-Null

            foreach ($key in $arguments.Keys) {
                $this.PowerShell.AddParameter($key, $arguments[$key]) | Out-Null
            }

            $this.Status = [JobStatus]::Running
            $this.StartedAtUtc = [datetime]::UtcNow
            $this.NextStallLogUtc = $this.StartedAtUtc.AddSeconds($this.StallWarnAfterSeconds)
            $this.AsyncResult = $this.PowerShell.BeginInvoke()
            $this.Logger.LogDebug("[$($this.HostName)] Started $($this.JobType) job.")
        }
        catch {
            $this.Status = [JobStatus]::Failed
            $this.Logger.LogException("[$($this.HostName)] Failed to start $($this.JobType) job", $_)
            $this.Logs.Enqueue("Exception: $_")
        }
    }

    [void] Poll() {
        if ($this.Status -ne [JobStatus]::Running) { return }

        if ($this.AsyncResult.IsCompleted) {
            try {
                $this.Result = $this.PowerShell.EndInvoke($this.AsyncResult)
                $this.Status = if ($this.PowerShell.HadErrors) { [JobStatus]::Failed }
                else { [JobStatus]::Completed }

                if ($this.PowerShell.HadErrors) {
                    if ($this.PowerShell.Streams.Error.Count -gt 0) {
                        $this.FailureMessage = [string]$this.PowerShell.Streams.Error[0]
                    }
                    foreach ($err in $this.PowerShell.Streams.Error) {
                        $this.Logs.Enqueue("Error: $err")
                        $this.Logger.LogError("[$($this.HostName)] $($this.JobType) error: $err")
                    }
                }
                else {
                    $this.Logger.LogDebug("[$($this.HostName)] $($this.JobType) job completed.")
                }
            }
            catch {
                $this.Status = [JobStatus]::Failed
                $this.FailureMessage = $_.Exception.Message
                $this.Logs.Enqueue("Exception: $_")
                $this.Logger.LogException("[$($this.HostName)] $($this.JobType) job failed during completion", $_)
            }
        }
        elseif ($this.NextStallLogUtc -ne [datetime]::MinValue -and
            [datetime]::UtcNow -ge $this.NextStallLogUtc) {
            # MinValue = the job reached Running without Start() arming the heartbeat
            # (test doubles do this); never treat that as an instant stall.
            $this.LogStallHeartbeat()
        }

        $this.DrainStream($this.PowerShell.Streams.Information)
        $this.DrainStream($this.PowerShell.Streams.Verbose)
        $this.DrainStream($this.PowerShell.Streams.Warning)
        $this.DrainStream($this.PowerShell.Streams.Error)
    }

    # One WARN per interval while a job neither completes nor fails - the difference
    # between "the app just went quiet" and a log that says where the time is going.
    hidden [void] LogStallHeartbeat() {
        $elapsed = [long]([datetime]::UtcNow - $this.StartedAtUtc).TotalSeconds
        $pool = 'unknown'
        try {
            $p = [RunspaceManager]::GetPool()
            $pool = "$($p.GetAvailableRunspaces())/$($p.GetMaxRunspaces()) free"
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
        $this.Logger.LogWarning(
            "[$($this.HostName)] $($this.JobType) job still running after $elapsed s " +
            "(pool: $pool, state: $state$firstError). 0 free means it is queued behind " +
            "busy or stuck runspaces; otherwise the worker itself has not returned.")
        $this.NextStallLogUtc = [datetime]::UtcNow.AddSeconds($this.StallRepeatSeconds)
    }

    [void] DrainStream($stream) {
        if (-not $stream) { return }
        foreach ($item in $stream.ReadAll()) {
            $this.Logs.Enqueue($item.ToString())
        }
    }

    [void] Cleanup() {
        if ($this.PowerShell) { $this.PowerShell.Dispose() }
        if ($this.TempConfigPath -and (Test-Path $this.TempConfigPath)) {
            Remove-Item $this.TempConfigPath -Force -ErrorAction SilentlyContinue
        }
    }
}
