using module ".\LogService.psm1"

<#
.SYNOPSIS
    Diagnostic watchdog that logs when the WPF dispatcher (UI thread) is blocked.

.DESCRIPTION
    A trivial-work DispatcherTimer on the UI thread records the gap since its previous
    tick. A gap far larger than the interval means the dispatcher was blocked in
    between - e.g. the STA thread contending on the process-wide CLR loader lock while
    a pool thread cold-loads a worker path (the known disk-scan-mid-scan freeze). Pairs
    with the worker-side timing in WorkerServices.RunDiskScanPhase: the worker log
    (pool thread) survives the freeze and names the slow cold-load; this log confirms
    the UI thread actually stalled.

.NOTES
    Diagnostic only - remove once the freeze is pinned. Catches stalls that recover
    (it logs on the first tick after the dispatcher comes back); a permanent hang stops
    the timer, so the worker-side start/done logs are the signal for that case.
#>
class DispatcherWatchdog {
    hidden [LogService] $Logger
    hidden [int] $ThresholdMs
    hidden [System.Windows.Threading.DispatcherTimer] $Timer
    hidden [datetime] $LastTick

    DispatcherWatchdog([LogService] $logger, [int] $thresholdMs) {
        $this.Logger = $logger
        $this.ThresholdMs = $thresholdMs
    }

    [void] Start() {
        $self = $this
        $this.LastTick = [datetime]::UtcNow
        $this.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $this.Timer.Add_Tick({ $self.OnTick() }.GetNewClosure())
        $this.Timer.Start()
    }

    [void] OnTick() {
        $now = [datetime]::UtcNow
        $gapMs = ($now - $this.LastTick).TotalMilliseconds
        $this.LastTick = $now
        if ($gapMs -gt $this.ThresholdMs) {
            $this.Logger.LogWarning(
                "UI dispatcher was blocked ~$([int]$gapMs) ms (tick interval is 250 ms) - possible CLR loader-lock stall.")
        }
    }
}
