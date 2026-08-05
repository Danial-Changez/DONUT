using module '.\LogService.psm1'

<#
.SYNOPSIS
    Static manager for the shared RunspacePool that runs remote jobs in parallel.

.DESCRIPTION
    Owns two process-wide RunspacePools and exposes Initialize / GetPool /
    GetInteractivePool / Close. The worker pool (sized to the configured throttle
    limit) is what AsyncJob borrows from; the interactive pool is a small fixed
    lane for in-process scripts that a user is waiting on. Pre-warming every
    runspace at startup keeps the CLR module-loader lock off the hot path so
    concurrent jobs never block the UI. Optionally logs lifecycle events.

.NOTES
    The pools are separate because they starve each other otherwise: every worker
    job holds its runspace for the whole child-process lifetime, so a fleet-wide
    scan pins all of them for minutes and a Lens or AD lookup submitted meanwhile
    queues behind it and never dispatches.

    InteractiveSize is 4 because the AD finder's fan-out is one job per configured
    forest and the default is four; at 3 the last forest queued on every single
    search, not just under contention. It is still a fixed number rather than a
    count of forests - deriving it would put a startup cost (each runspace pays a
    serialized using-module compile at warm) behind a value users edit, which is
    the coupling the worker/interactive split exists to avoid.
#>
class RunspaceManager {
    static [System.Management.Automation.Runspaces.RunspacePool] $RunspacePool
    static [System.Management.Automation.Runspaces.RunspacePool] $InteractivePool
    static [LogService] $Logger = $null

    # Fixed, not throttle-derived: four so a whole AD fan-out dispatches at once. See .NOTES.
    static [int] $InteractiveSize = 4

    # Static like the pool it logs for. When unset, logging is silently skipped.
    static [void] SetLogger([LogService]$logger) {
        [RunspaceManager]::Logger = $logger
    }

    hidden static [void] Log([string]$level, [string]$message) {
        if ($null -ne [RunspaceManager]::Logger) {
            [RunspaceManager]::Logger.WriteLog($level, $message)
        }
    }

    # Lazy-init fallback when nothing configured the pool first. min = max because idle
    # cleanup only disposes above the minimum, so a lower floor lets warm runspaces die.
    static [void] Initialize() {
        [RunspaceManager]::Initialize(5, 5)
    }

    static [void] Initialize([int]$MinRunspaces, [int]$MaxRunspaces) {
        $interactive = [RunspaceManager]::InteractiveSize
        if (-not [RunspaceManager]::RunspacePool) {
            try {
                # Pool dispatch runs on ThreadPool threads, so raise the floor before opening.
                $floor = [Math]::Max(16, ($MaxRunspaces + $interactive) * 2)
                [void][System.Threading.ThreadPool]::SetMinThreads($floor, $floor)
                [RunspaceManager]::Log("INFO", "ThreadPool min threads raised to $floor (worker+IOCP) so pool dispatch never starves.")
                [RunspaceManager]::RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($MinRunspaces, $MaxRunspaces)
                [RunspaceManager]::RunspacePool.Open()
                [RunspaceManager]::Log("INFO", "Runspace pool opened (min=$MinRunspaces, max=$MaxRunspaces).")
            }
            catch {
                [RunspaceManager]::Log("ERROR", "Failed to open runspace pool: $($_.Exception.Message)")
                throw
            }
        }
        if (-not [RunspaceManager]::InteractivePool) {
            try {
                # min = max here too, so warmed interactive runspaces never die and cold-load.
                [RunspaceManager]::InteractivePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($interactive, $interactive)
                [RunspaceManager]::InteractivePool.Open()
                [RunspaceManager]::Log("INFO", "Interactive runspace pool opened (min=max=$interactive).")
            }
            catch {
                # Non-fatal: GetInteractivePool falls back to the worker pool, degraded but alive.
                [RunspaceManager]::Log("ERROR", "Failed to open the interactive runspace pool; interactive lookups will share the worker pool: $($_.Exception.Message)")
            }
        }
    }

    static [System.Management.Automation.Runspaces.RunspacePool] GetPool() {
        if (-not [RunspaceManager]::RunspacePool) {
            [RunspaceManager]::Initialize()
        }
        return [RunspaceManager]::RunspacePool
    }

    # The lane for in-process scripts a user is waiting on (AD search, Lens, unlock).
    # Falls back to the worker pool rather than throwing if the split pool never opened.
    static [System.Management.Automation.Runspaces.RunspacePool] GetInteractivePool() {
        if (-not [RunspaceManager]::InteractivePool) {
            [RunspaceManager]::Initialize()
        }
        if (-not [RunspaceManager]::InteractivePool) {
            return [RunspaceManager]::GetPool()
        }
        return [RunspaceManager]::InteractivePool
    }

    static [void] Close() {
        if ([RunspaceManager]::InteractivePool) {
            try {
                [RunspaceManager]::InteractivePool.Close()
                [RunspaceManager]::InteractivePool.Dispose()
                [RunspaceManager]::Log("INFO", "Interactive runspace pool closed.")
            }
            catch {
                [RunspaceManager]::Log("WARN", "Error while closing the interactive runspace pool: $($_.Exception.Message)")
            }
            finally {
                [RunspaceManager]::InteractivePool = $null
            }
        }
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
