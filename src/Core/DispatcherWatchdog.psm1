using module ".\LogService.psm1"

<#
.SYNOPSIS
    Diagnostic watchdog that logs when the WPF dispatcher (UI thread) stalls.

.DESCRIPTION
    A trivial 250 ms DispatcherTimer measures the gap since its own last tick; a gap far
    over the interval means the STA thread was blocked or saturated. Each warning carries
    the GC collection-count deltas across the gap so the log discriminates the causes: a
    gen-2 delta > 0 points at a blocking GC (all threads suspended, e.g. LOH churn on a
    pool thread), while +0/+0/+0 points at loader-lock contention or synchronous UI work.
    Pairs with the worker-side timing in WorkerServices.RunDiskScanPhase.

.NOTES
    A permanent live diagnostic, shipped in production builds. It catches stalls that
    recover. A hang that never recovers stops the timer itself, so the worker-side
    start/done logs cover that case.

    DispatcherTimer ticks only fire while a message pump runs, so the span before the
    first pump (or between two pumps, e.g. login dialog close -> Application.Run) would
    be charged to the next tick as a fake multi-second "block". The first measurement
    after Start()/Reset() is therefore discarded; call Reset() whenever a new message
    pump is about to run.
#>
class DispatcherWatchdog {
    hidden [LogService] $Logger
    hidden [int] $ThresholdMs
    hidden [System.Windows.Threading.DispatcherTimer] $Timer
    hidden [datetime] $LastTick
    hidden [bool] $SkipNextGap = $true
    hidden [int[]] $GcCounts = @(0, 0, 0)

    DispatcherWatchdog([LogService] $logger, [int] $thresholdMs) {
        $this.Logger = $logger
        $this.ThresholdMs = $thresholdMs
    }

    [void] Start() {
        $self = $this
        $this.Reset()
        $this.Timer = [System.Windows.Threading.DispatcherTimer]::new()
        $this.Timer.Interval = [TimeSpan]::FromMilliseconds(250)
        $this.Timer.Add_Tick({ $self.OnTick() }.GetNewClosure())
        $this.Timer.Start()
    }

    # Call right before a new message pump starts (e.g. Application.Run after the login
    # dialog closed): the pumpless span since the last tick is dead time, not a block.
    [void] Reset() {
        $this.LastTick = [datetime]::UtcNow
        $this.SkipNextGap = $true
        $this.SnapshotGc()
    }

    hidden [void] SnapshotGc() {
        $this.GcCounts = @(
            [System.GC]::CollectionCount(0),
            [System.GC]::CollectionCount(1),
            [System.GC]::CollectionCount(2))
    }

    [void] OnTick() {
        $now = [datetime]::UtcNow
        $gapMs = ($now - $this.LastTick).TotalMilliseconds
        $this.LastTick = $now
        if ($this.SkipNextGap) {
            # First tick after Start/Reset: the gap includes pre-pump time, not a block.
            $this.SkipNextGap = $false
            $this.SnapshotGc()
            return
        }
        if ($gapMs -gt $this.ThresholdMs) {
            $g0 = [System.GC]::CollectionCount(0) - $this.GcCounts[0]
            $g1 = [System.GC]::CollectionCount(1) - $this.GcCounts[1]
            $g2 = [System.GC]::CollectionCount(2) - $this.GcCounts[2]
            $this.Logger.LogWarning(
                "UI dispatcher was blocked ~$([int]$gapMs) ms (tick interval is 250 ms); " +
                "GC gen0/1/2 +$g0/+$g1/+$g2 across the gap (gen2 > 0 suggests a blocking " +
                "GC; +0/+0/+0 suggests loader-lock or synchronous UI work).")
        }
        $this.SnapshotGc()
    }
}
