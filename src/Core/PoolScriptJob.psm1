using module ".\RunspaceManager.psm1"
using module ".\LogService.psm1"

<#
.SYNOPSIS
    Shared mechanics for in-process pool script jobs (the "Vehicle B" path).

.DESCRIPTION
    One home for the start / complete / async-stop / reap plumbing that
    FinderPresenter and MainPresenter each hand-rolled around
    PowerShell.Create() + the shared RunspacePool. The job envelope stays a
    plain hashtable (@{ Ps; Handle; StartedAt }) so poll loops can attach per-job
    state (Token, Upn, OnDone, ...) the way they always have.

.NOTES
    StartedAt is stamped immediately before BeginInvoke, which is the only place that
    can see the whole dispatch. Every poll loop wants it, and each one that stamped after
    Start returned was silently charging nothing for the pool queue wait - the number that
    says whether a job waited for a runspace or the work itself was slow.

    Worker JobKind operations do NOT come through here - they are AsyncJobs
    running in isolated child processes (WorkerProcess). This path is only for
    scripts that must run in-process on the pool (AD search, Lens broker,
    unlock, startup task). That separation is enforced by pool identity, not
    convention: these run on the interactive pool so they can never queue behind
    a fleet of worker jobs holding every runspace (see RunspaceManager).
#>
class PoolScriptJob {

    # Throws on failure so each call site keeps its own catch, log and toast behavior.
    # Returns a job envelope of Ps, Handle and StartedAt.
    static [hashtable] Start([string]$scriptPath, [hashtable]$parameters) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = [RunspaceManager]::GetInteractivePool()
        $ps.AddCommand($scriptPath) | Out-Null
        foreach ($k in $parameters.Keys) { $ps.AddParameter($k, $parameters[$k]) | Out-Null }
        # Stamped here, not by the caller: a later stamp loses the pool queue wait. See .NOTES.
        $started = [datetime]::UtcNow
        return @{ Ps = $ps; Handle = $ps.BeginInvoke(); StartedAt = $started }
    }

    # EndInvoke + dispose for the generic case: invoke errors log and yield $null so a
    # poll loop keeps draining. Loops needing the error or the streams do their own.
    static [object] Complete([hashtable]$job, [LogService]$logger) {
        $log = [LogService]::Coalesce($logger)
        $result = $null
        try { $result = $job.Ps.EndInvoke($job.Handle) }
        catch { $log.LogException("Pool job failed", $_) }
        try { $job.Ps.Dispose() }
        catch { $log.LogDebug("Pool job dispose failed: $($_.Exception.Message)") }
        return $result
    }

    # Never blocks the UI thread: finished jobs dispose now, running ones are async-stopped
    # into $stoppingList. Returns $true when parked so the caller can start its reap timer.
    static [bool] DisposeSafe([object]$ps, [System.Collections.IList]$stoppingList, [LogService]$logger) {
        if ($null -eq $ps) { return $false }
        $log = [LogService]::Coalesce($logger)
        try {
            if ([string]$ps.InvocationStateInfo.State -in @('Running', 'Stopping')) {
                # No callback: BeginStop fires it runspace-less, where any scriptblock throws.
                $stoppingList.Add(@{ Ps = $ps; StopHandle = $ps.BeginStop($null, $null) })
                return $true
            }
            $ps.Dispose()
        }
        catch { $log.LogDebug("Job dispose failed: $($_.Exception.Message)") }
        return $false
    }

    # Disposes each parked pipeline only once its stop HANDLE completes. The pipeline state
    # goes terminal while the stop thread still runs, and disposing then crashes the app.
    static [bool] ReapStopping([System.Collections.IList]$stoppingList, [LogService]$logger) {
        $log = [LogService]::Coalesce($logger)
        for ($i = $stoppingList.Count - 1; $i -ge 0; $i--) {
            $entry = $stoppingList[$i]
            if (-not $entry.StopHandle.IsCompleted) { continue }
            # EndStop joins the stop thread, so nothing of the stop can outlive the dispose.
            try { $entry.Ps.EndStop($entry.StopHandle) }
            catch { $log.LogDebug("Stop completion failed: $($_.Exception.Message)") }
            try { $entry.Ps.Dispose() }
            catch { $log.LogDebug("Stopped-job dispose failed: $($_.Exception.Message)") }
            $stoppingList.RemoveAt($i)
        }
        return ($stoppingList.Count -eq 0)
    }
}
