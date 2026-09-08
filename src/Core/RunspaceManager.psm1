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
    concurrent jobs never block the UI. Lifecycle events go to the static Logger,
    a no-op until DonutApp assigns the real one.

.NOTES
    The pools are separate because they starve each other otherwise: every worker
    job holds its runspace for the whole child-process lifetime, so a fleet-wide
    scan pins all of them for minutes and a Lens or AD lookup submitted meanwhile
    queues behind it and never dispatches.

    InteractiveSize follows the configured forest count, because the AD finder's
    fan-out is one job per forest and a pool smaller than that queues on every
    single search rather than only under contention. It was fixed at 4 for the
    four-forest default, and a ten-forest site paid for it: search legs whose own
    directory time was 350-850ms landed 1.4-6.5s late, all of it queue wait, and
    lens jobs sharing the lane made it worse. The floor stays 4 and the ceiling is
    12, since each runspace pays a serialized using-module compile at warm, so a
    long domain list cannot turn startup into a stall. SizeInteractiveFor must run
    before Initialize; after the pool is open the size is fixed.
#>
class RunspaceManager {
    static [System.Management.Automation.Runspaces.RunspacePool] $RunspacePool
    static [System.Management.Automation.Runspaces.RunspacePool] $InteractivePool
    # Static like the pools it logs for. The no-op default means no null checks anywhere.
    static [LogService] $Logger = [NullLogService]::new()

    # Not throttle-derived: one slot per forest so a whole AD fan-out dispatches at once.
    static [int] $InteractiveSize = 4

    # Sizes the interactive lane to the forest fan-out. Must precede Initialize. See .NOTES.
    static [void] SizeInteractiveFor([int]$forests) {
        if ([RunspaceManager]::InteractivePool) { return }
        $size = [Math]::Max(4, [Math]::Min(12, $forests))
        [RunspaceManager]::InteractiveSize = $size
        [RunspaceManager]::Logger.WriteLog("INFO",
            "Interactive pool sized to $size for $forests configured forest(s).")
    }

    # Lazy-init fallback when nothing configured the pool first. min = max because idle
    # cleanup only disposes above the minimum, so a lower floor lets warm runspaces die.
    static [void] Initialize() {
        [RunspaceManager]::Initialize(5, 5)
    }

    static [void] Initialize([int]$MinRunspaces, [int]$MaxRunspaces) {
        $interactive = [RunspaceManager]::InteractiveSize
        $factory = [System.Management.Automation.Runspaces.RunspaceFactory]
        if (-not [RunspaceManager]::RunspacePool) {
            try {
                # Pool dispatch runs on ThreadPool threads, so raise the floor before opening.
                $floor = [Math]::Max(16, ($MaxRunspaces + $interactive) * 2)
                [void][System.Threading.ThreadPool]::SetMinThreads($floor, $floor)
                [RunspaceManager]::Logger.WriteLog("INFO",
                    "ThreadPool min threads raised to $floor (worker+IOCP) so pool dispatch never starves.")
                [RunspaceManager]::RunspacePool = $factory::CreateRunspacePool($MinRunspaces, $MaxRunspaces)
                [RunspaceManager]::RunspacePool.Open()
                [RunspaceManager]::Logger.WriteLog("INFO",
                    "Runspace pool opened (min=$MinRunspaces, max=$MaxRunspaces).")
            } catch {
                [RunspaceManager]::Logger.WriteLog("ERROR", "Failed to open runspace pool: $($_.Exception.Message)")
                throw
            }
        }
        if (-not [RunspaceManager]::InteractivePool) {
            try {
                # min = max here too, so warmed interactive runspaces never die and cold-load.
                [RunspaceManager]::InteractivePool = $factory::CreateRunspacePool($interactive, $interactive)
                [RunspaceManager]::InteractivePool.Open()
                [RunspaceManager]::Logger.WriteLog("INFO", "Interactive runspace pool opened (min=max=$interactive).")
            } catch {
                # Non-fatal: GetInteractivePool falls back to the worker pool, degraded but alive.
                [RunspaceManager]::Logger.WriteLog("ERROR", "Failed to open the interactive runspace pool; " +
                    "interactive lookups will share the worker pool: $($_.Exception.Message)")
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
                [RunspaceManager]::Logger.WriteLog("INFO", "Interactive runspace pool closed.")
            } catch {
                [RunspaceManager]::Logger.WriteLog("WARN",
                    "Error while closing the interactive runspace pool: $($_.Exception.Message)")
            } finally {
                [RunspaceManager]::InteractivePool = $null
            }
        }
        if ([RunspaceManager]::RunspacePool) {
            try {
                [RunspaceManager]::RunspacePool.Close()
                [RunspaceManager]::RunspacePool.Dispose()
                [RunspaceManager]::Logger.WriteLog("INFO", "Runspace pool closed.")
            } catch {
                [RunspaceManager]::Logger.WriteLog("WARN", "Error while closing runspace pool: $($_.Exception.Message)")
            } finally {
                [RunspaceManager]::RunspacePool = $null
            }
        }
    }
}
