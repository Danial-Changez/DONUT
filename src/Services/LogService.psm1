class LogService {
    [string] $LogFilePath
    [System.Object] $SyncRoot

    LogService([string]$logDirectory) {
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        $this.LogFilePath = Join-Path $logDirectory "Donut.log"
        $this.SyncRoot = [System.Object]::new()
    }

    [void] LogInfo([string]$message) {
        $this.WriteLog("INFO", $message)
    }

    [void] LogError([string]$message) {
        $this.WriteLog("ERROR", $message)
    }

    [void] LogWarning([string]$message) {
        $this.WriteLog("WARN", $message)
    }

    [void] WriteLog([string]$level, [string]$message) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$level] $message"
        
        # Simple thread safety for file write
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            Add-Content -Path $this.LogFilePath -Value $logEntry
        }
        finally {
            [System.Threading.Monitor]::Exit($this.SyncRoot)
        }
    }

    [string[]] GetRecentLogs([int]$count) {
        [System.Threading.Monitor]::Enter($this.SyncRoot)
        try {
            if (Test-Path $this.LogFilePath) {
                return Get-Content -Path $this.LogFilePath -Tail $count
            }
            return @()
        }
        finally {
            [System.Threading.Monitor]::Exit($this.SyncRoot)
        }
    }
}
