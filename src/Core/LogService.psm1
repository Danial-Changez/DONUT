<#
.SYNOPSIS
    Thread-safe leveled file logger, plus a NullLogService no-op.

.DESCRIPTION
    Writes [INFO]/[WARN]/[ERROR]/[DEBUG] lines to a per-run log file, with an
    exception helper. NullLogService is the no-op used when a collaborator is
    constructed without a logger; Coalesce returns the given logger or a
    NullLogService so callers never null-check. DEBUG is gated by DebugEnabled
    (composition points set it from the 'debugLogging' setting or the
    Start-Donut -DebugLog session override; the class default stays verbose
    so tests and diagnostic tools see everything).
#>
class LogService {
    [string] $LogFilePath
    # Gates LogDebug only - INFO/WARN/ERROR always flow.
    [bool] $DebugEnabled = $true

    # Parameterless initializer for derived no-op loggers (e.g. NullLogService).
    # Does not bind a file path; WriteLog must be overridden by the derived type.
    LogService() {
    }

    LogService([string]$logDirectory) {
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }
        $this.LogFilePath = Join-Path $logDirectory "Donut.log"
    }

    # Returns the supplied logger, or a NullLogService no-op when $null - collapses the
    # repeated "logger or null-object" constructor guard to one call.
    static [LogService] Coalesce([LogService]$logger) {
        if ($null -eq $logger) { return [NullLogService]::new() }
        return $logger
    }

    # Rolls an oversized Donut.log to Donut.old.log (replacing the previous roll).
    # Main process only, before the logger opens: workers append mid-run and a
    # rotation under them would tear their stream. Best-effort - a locked or
    # missing file just skips the roll.
    static [void] Rotate([string]$logDirectory, [long]$maxBytes) {
        try {
            $log = Join-Path $logDirectory 'Donut.log'
            $file = Get-Item -LiteralPath $log -ErrorAction Stop
            if ($file.Length -gt $maxBytes) {
                Move-Item -LiteralPath $log -Destination (Join-Path $logDirectory 'Donut.old.log') -Force -ErrorAction Stop
            }
        }
        catch {
            # No log yet, or another process holds it open - skip this launch.
        }
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
        if (-not $this.DebugEnabled) { return }
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

    # Lock-free atomic append (Append mode + ReadWrite sharing, one line per Write):
    # logging must never block the app (architecture/runspaces-and-workers: logging).
    [void] WriteLog([string]$level, [string]$message) {
        $timestamp = [datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')
        $line = "[$timestamp] [$level] $message" + [System.Environment]::NewLine
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($line)
        try {
            $fs = [System.IO.FileStream]::new($this.LogFilePath,
                [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write,
                [System.IO.FileShare]::ReadWrite)
            try { $fs.Write($bytes, 0, $bytes.Length) }
            finally { $fs.Dispose() }
        }
        catch {
            # A failed log write has nowhere to log itself; swallowing here is the
            # only option that cannot recurse or take the caller down with it.
        }
    }

}

# Null-object logger: the safe default when no logger is injected. Every write is
# a no-op, so dependents can call $this.Logger.Log*(...) without null checks.
class NullLogService : LogService {
    NullLogService() : base() {}

    [void] WriteLog([string]$level, [string]$message) { }
}
