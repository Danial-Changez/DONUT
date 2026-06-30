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
    [string] $FailureMessage = ''   # first error text when Status is Failed (survives the runspace boundary)
    [string] $TempConfigPath
    [System.IAsyncResult] $AsyncResult
    [LogService] $Logger

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
                $this.Status = if ($this.PowerShell.HadErrors) { [JobStatus]::Failed } else { [JobStatus]::Completed }

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

        # Drain output streams
        $this.DrainStream($this.PowerShell.Streams.Information)
        $this.DrainStream($this.PowerShell.Streams.Verbose)
        $this.DrainStream($this.PowerShell.Streams.Warning)
        $this.DrainStream($this.PowerShell.Streams.Error)
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
