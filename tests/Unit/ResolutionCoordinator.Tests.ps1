<#
    Unit tests for ResolutionCoordinator. WPF-free (the coordinator reaches the detail
    panel only through the duck-typed $Home), so no assembly wrapper is needed. Fakes
    the shared HostResolver and the HomePresenter back-ref, then drives CompleteResolve
    and PrefetchIp directly.
#>
using module "..\..\src\UI\Presenters\ResolutionCoordinator.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\ResolveProcessJob.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\JobEnums.psm1"
using module "..\..\src\Services\HostResolver.psm1"

# --- Test doubles -----------------------------------------------------------

# Records the resolver mutations CompleteResolve / PrefetchIp make. base($null, $null)
# is safe because RemoteJobService's constructor only stores its refs.
class FakeHostResolver : HostResolver {
    [bool] $NeedsResolveResult = $true
    [string] $CachedIp = ''
    [string] $ActiveDc
    [System.Collections.Generic.List[string]] $Cleared
    [hashtable] $Verdicts
    FakeHostResolver() : base($null, $null) {
        $this.Cleared = [System.Collections.Generic.List[string]]::new()
        $this.Verdicts = @{}
    }
    [bool] NeedsResolve([string]$h) { return $this.NeedsResolveResult }
    [void] MarkInFlight([string]$h) {}
    [void] ClearInFlight([string]$h) { $this.Cleared.Add($h) }
    [string] GetCachedIp([string]$h) { return $this.CachedIp }
    [void] SetActiveDc([string]$dc) { $this.ActiveDc = $dc }
    [void] CacheVerdict([string]$h, [string]$ip, [bool]$online) { $this.Verdicts[$h] = @($ip, $online) }
    [void] CacheName([string]$h, [string]$n) {}
    [hashtable] PrepareResolveFast([string]$h) {
        return @{ ScriptPath = 'ResolveWorker.ps1'; TempConfigPath = $null; Arguments = @{ HostName = $h } }
    }
}

# A fast job that never spawns a process, so tests flip Status/ProcessFault directly.
class FakeFastJob : ResolveProcessJob {
    FakeFastJob([string]$h) : base($h, [JobKind]::Resolve, $null) {}
    [void] Start([string]$s, [hashtable]$a, [string]$t) { $this.Status = [JobStatus]::Running }
}

# Overrides the two construction seams so no real child pwsh / pool job ever starts.
class TestableCoordinator : ResolutionCoordinator {
    [System.Collections.Generic.List[object]] $FastJobs = [System.Collections.Generic.List[object]]::new()
    [System.Collections.Generic.List[string]] $ClassicStarts = [System.Collections.Generic.List[string]]::new()
    TestableCoordinator([AppConfig]$c, [LogService]$l, [object]$m, [object]$t,
        [HostResolver]$r, [object]$h) : base($c, $l, $m, $t, $r, $h) {}
    hidden [AsyncJob] NewFastResolveJob([string]$hostName) {
        $j = [FakeFastJob]::new($hostName)
        $this.FastJobs.Add($j)
        return $j
    }
    hidden [void] StartClassicResolve([string]$hostName) { $this.ClassicStarts.Add($hostName) }
}

# Records the pending-queue re-issue seams the coordinator hands back to.
class FakeHome {
    [System.Collections.Generic.List[object]] $ActiveJobs
    [string] $SelectedHost
    [object] $Detail
    [System.Collections.Generic.List[object]] $Reissued
    [System.Collections.Generic.List[string]] $DroppedRuns
    [System.Collections.Generic.List[string]] $Rendered
    FakeHome() {
        $this.ActiveJobs = [System.Collections.Generic.List[object]]::new()
        $this.Reissued = [System.Collections.Generic.List[object]]::new()
        $this.DroppedRuns = [System.Collections.Generic.List[string]]::new()
        $this.Rendered = [System.Collections.Generic.List[string]]::new()
    }
    # Mirrors AsyncJobPresenter.StartJob, the seam the coordinator launches jobs through.
    [object] StartJob([object]$job, [hashtable]$prep) {
        $job.Start($prep.ScriptPath, $prep.Arguments, $prep.TempConfigPath)
        $this.ActiveJobs.Add($job)
        return $job
    }
    [void] ReissueAfterResolve([string]$h, [bool]$online) { $this.Reissued.Add(@($h, $online)) }
    [void] DropPendingRunOnResolveFailure([string]$h) { $this.DroppedRuns.Add($h) }
    [void] RenderReachability([string]$h) { $this.Rendered.Add($h) }
    [object] GetRecord([string]$h) { return $null }
    [System.Collections.Generic.List[string]] $DeferredWarmReasons =
    [System.Collections.Generic.List[string]]::new()
    [void] StartDeferredWarms([string]$reason) { $this.DeferredWarmReasons.Add($reason) }
}

# Records SaveConfig for the warm/DC-persist path.
class FakeConfigManager {
    [int] $SaveCount = 0
    [void] SaveConfig([object]$config) { $this.SaveCount++ }
}

Describe "ResolutionCoordinator" {

    BeforeEach {
        $script:resolver = [FakeHostResolver]::new()
        $script:fakeHome = [FakeHome]::new()
        $script:cfgMgr = [FakeConfigManager]::new()
        $script:config = [AppConfig]::new('', '', '', @{})
        $script:coord = [ResolutionCoordinator]::new(
            $script:config, [LogService]::new($env:TEMP), $script:cfgMgr, $null,
            $script:resolver, $script:fakeHome)
    }

    Context "PrefetchIp" {
        It "is single-flight: skips a host that does not need resolving" {
            $script:resolver.NeedsResolveResult = $false
            $script:coord.PrefetchIp('PC1')
            $script:fakeHome.ActiveJobs.Count | Should -Be 0
        }
    }

    Context "CompleteResolve" {
        It "caches the verdict and hands re-issue back to Home on a Host result" {
            $job = [AsyncJob]::new('PC1', [JobKind]::Resolve)
            $job.Status = 'Completed'
            $job.Result = @([pscustomobject]@{ Mode = 'Host'; HostName = 'PC1'; Ip = '10.0.0.5'; Online = $true })

            $script:coord.CompleteResolve($job)

            $script:resolver.Verdicts['PC1'] | Should -Be @('10.0.0.5', $true)
            $script:fakeHome.Rendered | Should -Be @('PC1')
            $script:fakeHome.Reissued.Count | Should -Be 1
            $script:fakeHome.Reissued[0] | Should -Be @('PC1', $true)
        }

        It "clears the latch and drops the queued run on a failed resolve" {
            $job = [AsyncJob]::new('PC1', [JobKind]::Resolve)
            $job.Status = 'Failed'

            $script:coord.CompleteResolve($job)

            $script:resolver.Cleared | Should -Be @('PC1')          # single-flight latch released
            $script:fakeHome.DroppedRuns | Should -Be @('PC1')
            $script:fakeHome.Reissued.Count | Should -Be 0
        }

        It "sets + persists the active DC on a Warm result" {
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Status = 'Completed'
            $job.Result = @([pscustomobject]@{ Mode = 'Warm'; ActiveDc = 'DC01'; DomainControllers = @('DC01', 'DC02') })

            $script:coord.CompleteResolve($job)

            $script:resolver.ActiveDc | Should -Be 'DC01'
            $script:config.Settings['activeDomainController'] | Should -Be 'DC01'
            $script:cfgMgr.SaveCount | Should -Be 1
            # The DC warm ends the startup crunch, so the deferred warms release exactly once.
            $script:fakeHome.DeferredWarmReasons.Count | Should -Be 1
        }

        It "releases the deferred warms even when the DC warm FAILS" {
            # A failed warm must not strand the deferred warms on the fallback timer either.
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Status = 'Failed'
            $job.FailureMessage = 'boom'

            $script:coord.CompleteResolve($job)

            $script:fakeHome.DeferredWarmReasons.Count | Should -Be 1
        }

        It "does not re-save the config when the active DC is unchanged" {
            $script:config.Settings['activeDomainController'] = 'DC01'
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Status = 'Completed'
            $job.Result = @([pscustomobject]@{ Mode = 'Warm'; ActiveDc = 'DC01'; DomainControllers = @('DC01', 'DC02') })

            $script:coord.CompleteResolve($job)

            $script:cfgMgr.SaveCount | Should -Be 0
        }

        It "never persists the controller list - only the active DC is config state" {
            # 'domainControllers' was never read back, and the warm re-discovers it every launch.
            $job = [AsyncJob]::new('', [JobKind]::Resolve)
            $job.Status = 'Completed'
            $job.Result = @([pscustomobject]@{ Mode = 'Warm'; ActiveDc = 'DC01'; DomainControllers = @('DC01', 'DC03') })

            $script:coord.CompleteResolve($job)

            $script:config.Settings.ContainsKey('domainControllers') | Should -BeFalse
        }
    }

    Context "Fast resolve lane" {
        BeforeEach {
            $script:fastCoord = [TestableCoordinator]::new(
                $script:config, [LogService]::new($env:TEMP), $script:cfgMgr, $null,
                $script:resolver, $script:fakeHome)
        }

        # Marks a fast job terminal the way the pump would see it.
        BeforeAll {
            function Set-FastFault([object]$job, [string]$message = 'killed') {
                $job.Status = [JobStatus]::Failed
                $job.ProcessFault = $true
                $job.FailureMessage = $message
            }
        }

        It "prefetch uses the fast lane, caps concurrency at 4, and drains the FIFO overflow" {
            foreach ($i in 1..5) { $script:fastCoord.PrefetchIp("PC$i") }
            $script:fastCoord.FastJobs.Count | Should -Be 4       # the 5th queued, not started
            $script:fakeHome.ActiveJobs.Count | Should -Be 4

            $job = $script:fastCoord.FastJobs[0]
            $job.Status = [JobStatus]::Completed
            $job.Result = @{ Mode = 'Host'; HostName = 'PC1'; Ip = '10.0.0.5'; Online = $true }
            $script:fastCoord.CompleteResolve($job)

            $script:fastCoord.FastJobs.Count | Should -Be 5
            $script:fastCoord.FastJobs[4].HostName | Should -Be 'PC5'
        }

        It "a ProcessFault retries once on the classic path and releases the latch" {
            $script:fastCoord.PrefetchIp('PC1')
            $job = $script:fastCoord.FastJobs[0]
            Set-FastFault $job

            $script:fastCoord.CompleteResolve($job)

            $script:resolver.Cleared | Should -Be @('PC1')
            $script:fastCoord.ClassicStarts | Should -Be @('PC1')
            $script:fakeHome.DroppedRuns.Count | Should -Be 0     # retried, not dropped
        }

        It "a repeat fault before any verdict drops the queued run instead of looping" {
            $script:fastCoord.PrefetchIp('PC1')
            Set-FastFault $script:fastCoord.FastJobs[0]
            $script:fastCoord.CompleteResolve($script:fastCoord.FastJobs[0])

            $script:fastCoord.PrefetchIp('PC1')
            Set-FastFault $script:fastCoord.FastJobs[1]
            $script:fastCoord.CompleteResolve($script:fastCoord.FastJobs[1])

            $script:fastCoord.ClassicStarts | Should -Be @('PC1')   # only the first fell back
            $script:fakeHome.DroppedRuns | Should -Be @('PC1')
        }

        It "three consecutive faults latch the lane off for the session" {
            foreach ($i in 1..3) {
                $script:fastCoord.PrefetchIp("PC$i")
                Set-FastFault $script:fastCoord.FastJobs[$i - 1]
                $script:fastCoord.CompleteResolve($script:fastCoord.FastJobs[$i - 1])
            }

            $script:fastCoord.PrefetchIp('PC9')

            $script:fastCoord.FastJobs.Count | Should -Be 3         # no new fast child
            $script:fastCoord.ClassicStarts[$script:fastCoord.ClassicStarts.Count - 1] |
                Should -Be 'PC9'                                    # went down the worker path
        }

        It "a successful fast verdict resets the fault streak (latch counts CONSECUTIVE faults)" {
            foreach ($i in 1..2) {
                $script:fastCoord.PrefetchIp("PC$i")
                Set-FastFault $script:fastCoord.FastJobs[$i - 1]
                $script:fastCoord.CompleteResolve($script:fastCoord.FastJobs[$i - 1])
            }
            $script:fastCoord.PrefetchIp('PC3')
            $ok = $script:fastCoord.FastJobs[2]
            $ok.Status = [JobStatus]::Completed
            $ok.Result = @{ Mode = 'Host'; HostName = 'PC3'; Ip = '10.0.0.3'; Online = $true }
            $script:fastCoord.CompleteResolve($ok)

            $script:fastCoord.PrefetchIp('PC4')
            Set-FastFault $script:fastCoord.FastJobs[3]
            $script:fastCoord.CompleteResolve($script:fastCoord.FastJobs[3])

            # Streak reset by the success: one later fault must not latch the lane off.
            $script:fastCoord.PrefetchIp('PC5')
            $script:fastCoord.FastJobs[$script:fastCoord.FastJobs.Count - 1].HostName |
                Should -Be 'PC5'
        }
    }
}
