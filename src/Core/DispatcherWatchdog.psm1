using module ".\LogService.psm1"

<#
.SYNOPSIS
    Diagnostic watchdog that logs when the WPF dispatcher (UI thread) stalls.

.DESCRIPTION
    A trivial 250 ms DispatcherTimer measures the gap since its own last tick; a gap far
    over the interval means the STA thread was blocked - the suspected loader-lock
    contention while a pool thread cold-loads a worker path. Pairs with the worker-side
    timing in WorkerServices.RunDiskScanPhase to pin the disk-scan-mid-scan freeze.

.NOTES
    Diagnostic only; remove once the freeze is pinned. It catches stalls that recover; a
    permanent hang stops the timer, so the worker-side start/done logs cover that case.
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
