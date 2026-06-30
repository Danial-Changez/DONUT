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

    # Drives one polling pass over all active jobs. Safe to call when idle.
    [void] PumpJobs() {
        if (-not $this.ActiveJobs -or $this.ActiveJobs.Count -eq 0) { return }

        $processedAny = $false
        for ($i = $this.ActiveJobs.Count - 1; $i -ge 0; $i--) {
            $job = $this.ActiveJobs[$i]
            if (-not $job) { continue }
            $processedAny = $true

            $job.Poll()
            $this.OnJobPolled($job)

            if ($job.Status -in @([JobStatus]::Completed, [JobStatus]::Failed)) {
                $this.OnJobCompleted($job)
                $job.Cleanup()
                # Re-fetch the index: OnJobCompleted may append jobs (e.g. an
                # apply phase), but never reorders/removes earlier entries, so
                # the original index still points at this finished job.
                $this.ActiveJobs.RemoveAt($i)
            }
        }

        if ($processedAny) { $this.AfterPump() }
    }

    # --- Overridable hooks (no-op by default) ----------------------------------------

    # Per-tick, after Poll() and before the terminal-status check.
    [void] OnJobPolled([AsyncJob]$job) { }

    # Once, when $job reaches 'Completed'/'Failed', before Cleanup()/RemoveAt.
    [void] OnJobCompleted([AsyncJob]$job) { }

    # Once per tick that processed at least one job, after the loop.
    [void] AfterPump() { }
}
