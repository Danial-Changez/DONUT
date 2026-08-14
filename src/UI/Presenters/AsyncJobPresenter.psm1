using namespace System.Collections.Generic
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Models\JobEnums.psm1"

<#
.SYNOPSIS
    Shared base for presenters that drive background AsyncJobs on a timer.

.DESCRIPTION
    Owns the polling lifecycle once (PumpJobs, off a ~200ms DispatcherTimer):
    reverse-iterate $ActiveJobs, Poll() each job, and on a terminal status
    (Completed/Failed) do per-job completion work then Cleanup() + RemoveAt.

    Subclasses keep their unique behaviour via overridable hooks:
      - OnJobPolled($job)    runs every tick after Poll(), before the terminal
                             check (Home drains logs, drives the bar, refreshes
                             the card).
      - OnJobCompleted($job) runs once when a job reaches a terminal status,
                             before Cleanup()/RemoveAt (Home: driver match /
                             apply-phase transition / recents persistence).
      - AfterPump()          runs once at the end of a tick that processed jobs,
                             for batch work (Home: overview refresh + reboot notice).

.NOTES
    This base owns only the loop and the ActiveJobs list; subclasses construct
    their own DispatcherTimer and call PumpJobs from its Tick handler. WPF-free
    apart from the job collection.
#>
class AsyncJobPresenter {
    [System.Collections.Generic.List[AsyncJob]] $ActiveJobs

    AsyncJobPresenter() {
        $this.ActiveJobs = [List[AsyncJob]]::new()
    }

    # Starts a constructed job from its Prepare* hashtable and registers it with the pump.
    [AsyncJob] StartJob([AsyncJob]$job, [hashtable]$prep) {
        $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
        $this.ActiveJobs.Add($job)
        return $job
    }

    # Drives one polling pass over all active jobs. Safe to call when idle.
    [void] PumpJobs() {
        if (-not $this.ActiveJobs -or $this.ActiveJobs.Count -eq 0) { return }

        # A modal's nested loop re-fires this timer, so defer work that could stack a modal.
        $modal = $this.IsModalOpen()

        $processedAny = $false
        for ($i = $this.ActiveJobs.Count - 1; $i -ge 0; $i--) {
            $job = $this.ActiveJobs[$i]
            if (-not $job) { continue }
            $processedAny = $true

            $job.Poll()
            $this.OnJobPolled($job)

            if ($job.Status -in @([JobStatus]::Completed, [JobStatus]::Failed)) {
                if ($modal) { continue }   # leave the finished job for a later, non-modal tick
                $this.OnJobCompleted($job)
                $job.Cleanup()
                # OnJobCompleted only appends, so the index still points at this finished job.
                $this.ActiveJobs.RemoveAt($i)
            }
        }

        if ($processedAny -and -not $modal) { $this.AfterPump() }
    }

    # True when a modal dialog is open, so PumpJobs defers dialog-opening completion work.
    # Presenters that own a DialogPresenter override it, and the base is a no-op.
    [bool] IsModalOpen() { return $false }

    # --- Overridable hooks (no-op by default) ---

    # Per-tick, after Poll() and before the terminal-status check.
    [void] OnJobPolled([AsyncJob]$job) { }

    # Once, when $job reaches 'Completed'/'Failed', before Cleanup()/RemoveAt.
    [void] OnJobCompleted([AsyncJob]$job) { }

    # Once per tick that processed at least one job, after the loop.
    [void] AfterPump() { }
}
