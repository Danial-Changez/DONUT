using namespace System.Collections.Concurrent
using module '.\RunspaceManager.psm1'

class AsyncJob {
    [System.Management.Automation.PowerShell] $PowerShell
    [string] $HostName
    [string] $JobType      # 'Scan', 'UpdateScan', 'UpdateApply'
    [string] $Status       # 'Created', 'Running', 'Completed', 'Failed'
    [ConcurrentQueue[string]] $Logs
    [object] $Result
    [string] $TempConfigPath
    [System.IAsyncResult] $AsyncResult

    AsyncJob([string]$hostName, [string]$type) {
        $this.HostName = $hostName
        $this.JobType = $type
        $this.Status = 'Created'
        $this.Logs = [ConcurrentQueue[string]]::new()
    }

    [void] Start([string]$scriptPath, [hashtable]$arguments, [string]$tempConfigPath) {
        $this.TempConfigPath = $tempConfigPath
        
        $pool = [RunspaceManager]::GetPool()
        $this.PowerShell = [System.Management.Automation.PowerShell]::Create()
        $this.PowerShell.RunspacePool = $pool
        $this.PowerShell.AddCommand($scriptPath) | Out-Null
        
        foreach ($key in $arguments.Keys) {
            $this.PowerShell.AddParameter($key, $arguments[$key]) | Out-Null
        }

        $this.Status = 'Running'
        $this.AsyncResult = $this.PowerShell.BeginInvoke()
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
                    }
                }
            }
            catch {
                $this.Status = 'Failed'
                $this.Logs.Enqueue("Exception: $_")
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
