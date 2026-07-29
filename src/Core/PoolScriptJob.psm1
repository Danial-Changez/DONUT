using module ".\RunspaceManager.psm1"
using module ".\LogService.psm1"

<#
.SYNOPSIS
    Shared mechanics for in-process pool script jobs (the "Vehicle B" path).

.DESCRIPTION
    One home for the start / complete / async-stop / reap plumbing that
    FinderPresenter and MainPresenter each hand-rolled around
    PowerShell.Create() + the shared RunspacePool. The job envelope stays a
    plain hashtable (@{ Ps; Handle }) so poll loops can attach per-job state
    (Token, Upn, OnDone, ...) the way they always have.

.NOTES
    Worker JobKind operations do NOT come through here - they are AsyncJobs
    running in isolated child processes (WorkerProcess). This path is only for
    scripts that must run in-process on the pool (AD search, Lens broker,
    unlock, startup task). That separation is enforced by pool identity, not
    convention: these run on the interactive pool so they can never queue behind
    a fleet of worker jobs holding every runspace (see RunspaceManager).
#>
class PoolScriptJob {

    # Starts $scriptPath on the shared pool; throws on failure so each call site
    # keeps its own catch/log/toast behavior. Returns the @{ Ps; Handle } envelope.
    static [hashtable] Start([string]$scriptPath, [hashtable]$parameters) {
        $ps = [System.Management.Automation.PowerShell]::Create()
        $ps.RunspacePool = [RunspaceManager]::GetInteractivePool()
        $ps.AddCommand($scriptPath) | Out-Null
        foreach ($k in $parameters.Keys) { $ps.AddParameter($k, $parameters[$k]) | Out-Null }
        return @{ Ps = $ps; Handle = $ps.BeginInvoke() }
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
            if ($ps.InvocationStateInfo.State -eq 'Running') {
                # No scriptblock callback: BeginStop fires it on a runspace-less threadpool
                # thread, where any scriptblock throws before its body runs (crashing the app).
                $ps.BeginStop($null, $null) | Out-Null
                $stoppingList.Add($ps)
                return $true
            }
            $ps.Dispose()
        }
        catch { $log.LogDebug("Job dispose failed: $($_.Exception.Message)") }
        return $false
    }

    # Disposes each async-stopped pipeline once terminal (disposing a still-Stopping one
    # would block). Returns $true when the list drained so the caller can stop its timer.
    static [bool] ReapStopping([System.Collections.IList]$stoppingList, [LogService]$logger) {
        $log = [LogService]::Coalesce($logger)
        for ($i = $stoppingList.Count - 1; $i -ge 0; $i--) {
            $ps = $stoppingList[$i]
            $state = [string]$ps.InvocationStateInfo.State
            if ($state -ne 'Running' -and $state -ne 'Stopping') {
                try { $ps.Dispose() }
                catch { $log.LogDebug("Stopped-job dispose failed: $($_.Exception.Message)") }
                $stoppingList.RemoveAt($i)
            }
        }
        return ($stoppingList.Count -eq 0)
    }
}
