using namespace System.Collections.Concurrent
using module '.\RunspaceManager.psm1'
using module '.\LogService.psm1'

class AsyncJob {
    [System.Management.Automation.PowerShell] $PowerShell
    [string] $HostName
    [string] $JobType      # 'Scan', 'UpdateScan', 'UpdateApply'
    [string] $Status       # 'Created', 'Running', 'Completed', 'Failed'
    [ConcurrentQueue[string]] $Logs
    [object] $Result
    [string] $TempConfigPath
    [System.IAsyncResult] $AsyncResult
    [LogService] $Logger

    AsyncJob([string]$hostName, [string]$type) {
        $this.Initialize($hostName, $type, [NullLogService]::new())
    }

    AsyncJob([string]$hostName, [string]$type, [LogService]$logger) {
        $this.Initialize($hostName, $type, $logger)
    }

    hidden [void] Initialize([string]$hostName, [string]$type, [LogService]$logger) {
        if ($null -eq $logger) {
            $this.Logger = [NullLogService]::new()
        }
        else {
            $this.Logger = $logger
        }
        $this.HostName = $hostName
        $this.JobType = $type
        $this.Status = 'Created'
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

            $this.Status = 'Running'
            $this.AsyncResult = $this.PowerShell.BeginInvoke()
            $this.Logger.LogDebug("[$($this.HostName)] Started $($this.JobType) job.")
        }
        catch {
            $this.Status = 'Failed'
            $this.Logger.LogException("[$($this.HostName)] Failed to start $($this.JobType) job", $_)
            $this.Logs.Enqueue("Exception: $_")
        }
    }

    [void] Poll() {
        if ($this.Status -ne 'Running') { return }

        if ($this.AsyncResult.IsCompleted) {
            try {
                $this.Result = $this.PowerShell.EndInvoke($this.AsyncResult)
                $this.Status = if ($this.PowerShell.HadErrors) { 'Failed' } else { 'Completed' }

                if ($this.PowerShell.HadErrors) {
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
                $this.Status = 'Failed'
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
