using namespace System.Collections.Generic
using module "..\..\Core\AsyncJob.psm1"
using module "..\..\Models\JobEnums.psm1"

# AsyncJobPresenter
#
# Shared base for presenters that drive background AsyncJobs off a 200ms
# DispatcherTimer (Home, Battery). Both used to repeat the identical polling
# lifecycle in their own OnTimerTick: reverse-iterate $ActiveJobs, Poll() each
# job, and on a terminal status ('Completed'/'Failed') do per-job completion
# work then Cleanup() + RemoveAt. That loop now lives here once, in PumpJobs.
#
# Subclasses keep their UNIQUE behaviour via two overridable hooks:
#   - OnJobPolled($job)    : runs every tick after Poll(), before the terminal
#                            check (Home uses it to drain logs / drive the bar /
#                            refresh the card; Battery leaves it a no-op).
#   - OnJobCompleted($job) : runs once when a job reaches a terminal status,
#                            before Cleanup()/RemoveAt (Home: driver-match /
#                            apply-phase transition / recents persistence;
#                            Battery: WebBrowser navigation).
# AfterPump runs once at the end of a tick that processed jobs, for batch-level
# work (Home: overview refresh + manual-reboot notice).
#
# This base owns only the loop and the ActiveJobs list; subclasses construct
# their own DispatcherTimer (their constructor signatures are fixed) and call
# PumpJobs from its Tick handler. WPF-free apart from the job collection.

class AsyncJobPresenter {
    [System.Collections.Generic.List[AsyncJob]] $ActiveJobs
    hidden [bool] $IsPumping = $false   # re-entrancy guard (see PumpJobs)

    AsyncJobPresenter() {
        $this.ActiveJobs = [List[AsyncJob]]::new()
    }

    # Drives one polling pass over all active jobs. Safe to call when idle.
    #
    # OnJobCompleted/AfterPump may show a blocking modal (ShowDialog - the
    # apply-updates confirmation, the manual-reboot notice). ShowDialog runs a
    # nested message loop that keeps the free-running 200ms job timer ticking, so
    # the tick re-enters PumpJobs WHILE we're still inside OnJobCompleted - before
    # the finished job has been RemoveAt'd. Without a guard that re-entrant pass
    # re-processes the same completed job and stacks another dialog every tick (the
    # "UI freeze whenever a popup is involved"). The guard makes re-entrant calls
    # no-op; the in-flight pass finishes and removes the job once the dialog closes.
    [void] PumpJobs() {
        if ($this.IsPumping) { return }
        if (-not $this.ActiveJobs -or $this.ActiveJobs.Count -eq 0) { return }

        $this.IsPumping = $true
        try {
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
        finally {
            $this.IsPumping = $false
        }
    }

    # --- Overridable hooks (no-op by default) ----------------------------------------

    # Per-tick, after Poll() and before the terminal-status check.
    [void] OnJobPolled([AsyncJob]$job) { }

    # Once, when $job reaches 'Completed'/'Failed', before Cleanup()/RemoveAt.
    [void] OnJobCompleted([AsyncJob]$job) { }

    # Once per tick that processed at least one job, after the loop.
    [void] AfterPump() { }
}
