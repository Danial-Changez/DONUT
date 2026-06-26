using module '.\LogService.psm1'

class RunspaceManager {
    static [System.Management.Automation.Runspaces.RunspacePool] $RunspacePool
    static [LogService] $Logger = $null

    # Optionally attach a logger (the pool is managed statically, so logging is
    # too). When unset, logging is silently skipped.
    static [void] SetLogger([LogService]$logger) {
        [RunspaceManager]::Logger = $logger
    }

    hidden static [void] Log([string]$level, [string]$message) {
        if ($null -ne [RunspaceManager]::Logger) {
            [RunspaceManager]::Logger.WriteLog($level, $message)
        }
    }

    static [void] Initialize() {
        [RunspaceManager]::Initialize(1, 5)
    }

    static [void] Initialize([int]$MinRunspaces, [int]$MaxRunspaces) {
        if (-not [RunspaceManager]::RunspacePool) {
            try {
                [RunspaceManager]::RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($MinRunspaces, $MaxRunspaces)
                [RunspaceManager]::RunspacePool.Open()
                [RunspaceManager]::Log("INFO", "Runspace pool opened (min=$MinRunspaces, max=$MaxRunspaces).")
            }
            catch {
                [RunspaceManager]::Log("ERROR", "Failed to open runspace pool: $($_.Exception.Message)")
                throw
            }
        }
    }

    static [System.Management.Automation.Runspaces.RunspacePool] GetPool() {
        if (-not [RunspaceManager]::RunspacePool) {
            [RunspaceManager]::Initialize()
        }
        return [RunspaceManager]::RunspacePool
    }

    static [void] Close() {
        if ([RunspaceManager]::RunspacePool) {
            try {
                [RunspaceManager]::RunspacePool.Close()
                [RunspaceManager]::RunspacePool.Dispose()
                [RunspaceManager]::Log("INFO", "Runspace pool closed.")
            }
            catch {
                [RunspaceManager]::Log("WARN", "Error while closing runspace pool: $($_.Exception.Message)")
            }
            finally {
                [RunspaceManager]::RunspacePool = $null
            }
        }
    }
}
