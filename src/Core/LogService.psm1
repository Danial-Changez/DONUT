<#
.SYNOPSIS
    Thread-safe leveled file logger, plus a NullLogService no-op.

.DESCRIPTION
    Writes [INFO]/[WARN]/[ERROR]/[DEBUG] lines to a per-run log file under a lock,
    with exception and structured-event helpers. NullLogService is the no-op used
    when a collaborator is constructed without a logger; Coalesce returns the
    given logger or a NullLogService so callers never null-check.
#>
class LogService {
    [string] $LogFilePath
    [System.Object] $SyncRoot
    # Cross-INSTANCE write lock. A per-instance Monitor (SyncRoot) cannot serialize the
    # real contention: every worker runspace constructs its OWN LogService over the same
    # Donut.log (StartWorker), so with concurrent jobs two instances would collide inside
    # Add-Content (exclusive append handle) and silently LOSE lines - exactly when the
    # log matters most. A named mutex is a kernel object shared by every instance (and
    # runspace) in the session, keyed by the file path so different files don't contend.
    hidden [System.Threading.Mutex] $FileMutex

    # Parameterless initializer for derived no-op loggers (e.g. NullLogService).
    # Does not bind a file path; WriteLog must be overridden by the derived type.
    LogService() {
        $this.SyncRoot = [System.Object]::new()
    }

    LogService([string]$logDirectory) {
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        $this.LogFilePath = Join-Path $logDirectory "Donut.log"
        $this.SyncRoot = [System.Object]::new()
        $hash = [System.BitConverter]::ToString(
            [System.Security.Cryptography.SHA1]::HashData(
                [System.Text.Encoding]::UTF8.GetBytes($this.LogFilePath.ToLowerInvariant()))).Replace('-', '').Substring(0, 16)
        $this.FileMutex = [System.Threading.Mutex]::new($false, "Local\DonutLog-$hash")
    }

    # Returns the supplied logger, or a NullLogService no-op when it is $null.
    # Collapses the repeated "logger or null-object" guard in collaborators'
    # constructors to a single call.
    static [LogService] Coalesce([LogService]$logger) {
        if ($null -eq $logger) { return [NullLogService]::new() }
        return $logger
    }

    [void] LogInfo([string]$message) {
        $this.WriteLog("INFO", $message)
    }

    [void] LogWarning([string]$message) {
        $this.WriteLog("WARN", $message)
    }

    [void] LogError([string]$message) {
        $this.WriteLog("ERROR", $message)
    }

    [void] LogDebug([string]$message) {
        $this.WriteLog("DEBUG", $message)
    }

    # Logs an ERROR with the originating exception's type and message appended.
    # Pass the automatic $_ (ErrorRecord) from inside a catch block.
    [void] LogException([string]$message, [System.Management.Automation.ErrorRecord]$errorRecord) {
        $detail = "<no exception detail>"
        if ($null -ne $errorRecord -and $null -ne $errorRecord.Exception) {
            $detail = "$($errorRecord.Exception.GetType().Name): $($errorRecord.Exception.Message)"
        }
        $this.WriteLog("ERROR", "$message | $detail")
    }

    # Emits a structured, pipe-delimited entry: "<event>|key=value|key=value".
    # Field keys are sorted so the output is deterministic and machine-parseable.
    [void] LogStructured([string]$level, [string]$eventName, [hashtable]$fields) {
        $parts = [System.Collections.Generic.List[string]]::new()
        $parts.Add($eventName)
        if ($null -ne $fields) {
            foreach ($key in ($fields.Keys | Sort-Object)) {
                $parts.Add("$key=$($fields[$key])")
            }
        }
        $this.WriteLog($level, ($parts -join '|'))
    }

    [void] WriteLog([string]$level, [string]$message) {
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        $logEntry = "[$timestamp] [$level] $message"

        # Serialize against every other LogService instance writing this file (workers
        # construct their own). BOUNDED wait so logging can never hang a thread: on a
        # timeout, write anyway (worst case is the old best-effort behaviour). An
        # abandoned mutex (a runspace died holding it) still grants ownership - proceed.
        $owned = $false
        if ($null -ne $this.FileMutex) {
            try { $owned = $this.FileMutex.WaitOne(2000) }
            catch [System.Threading.AbandonedMutexException] { $owned = $true }
        }
        try {
            Add-Content -Path $this.LogFilePath -Value $logEntry -ErrorAction SilentlyContinue
        }
        finally {
            if ($owned) { $this.FileMutex.ReleaseMutex() }
        }
    }

    [string[]] GetRecentLogs([int]$count) {
        # Reads open the file shared; no need to hold the write mutex (a torn tail line
        # in a live view is acceptable, a blocked reader is not).
        if (Test-Path $this.LogFilePath) {
            return Get-Content -Path $this.LogFilePath -Tail $count
        }
        return @()
    }
}

# Null-object logger: the safe default when no logger is injected. Every write is
# a no-op, so dependents can call $this.Logger.Log*(...) without null checks.
class NullLogService : LogService {
    NullLogService() : base() {}

    [void] WriteLog([string]$level, [string]$message) { }

    [string[]] GetRecentLogs([int]$count) { return @() }
}
