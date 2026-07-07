# Unit tests for ResolutionCoordinator. WPF-free (the coordinator reaches the detail
# panel only through the duck-typed $Home), so no assembly wrapper is needed. Fakes
# the shared HostResolver + the HomePresenter back-ref and drives CompleteResolve /
# PrefetchIp directly.
using module "..\..\src\UI\Presenters\ResolutionCoordinator.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\JobEnums.psm1"
using module "..\..\src\Services\HostResolver.psm1"

# --- Test doubles -----------------------------------------------------------

# Records the resolver mutations CompleteResolve / PrefetchIp make. base($null, $null)
# is safe - RemoteJobService's constructor only stores its refs.
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
    [void] ReissueAfterResolve([string]$h, [bool]$online) { $this.Reissued.Add(@($h, $online)) }
    [void] DropPendingRunOnResolveFailure([string]$h) { $this.DroppedRuns.Add($h) }
    [void] RenderReachability([string]$h) { $this.Rendered.Add($h) }
    [object] GetRecord([string]$h) { return $null }
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

            $script:resolver.Verdicts['PC1'] | Should -Be @('10.0.0.5', $true)  # cached
            $script:fakeHome.Rendered | Should -Be @('PC1')                     # row refreshed
            $script:fakeHome.Reissued.Count | Should -Be 1                      # queue handed back
            $script:fakeHome.Reissued[0] | Should -Be @('PC1', $true)
        }

        It "clears the latch and drops the queued run on a failed resolve" {
            $job = [AsyncJob]::new('PC1', [JobKind]::Resolve)
            $job.Status = 'Failed'

            $script:coord.CompleteResolve($job)

            $script:resolver.Cleared | Should -Be @('PC1')          # single-flight latch released
            $script:fakeHome.DroppedRuns | Should -Be @('PC1')      # queued run dropped
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
        }
    }
}
