<#
    The wrapper loads WPF and Donut.Mvvm. HomePresenter's ctor composes XAML regions
    and starts timers, so the identity gate runs on an uninitialized instance with only
    the fields it reads set. Fakes subclass the two typed collaborators it talks to.
#>
using module "..\..\src\UI\Presenters\HomePresenter.psm1"
using module "..\..\src\UI\Presenters\InventoryPresenter.psm1"
using module "..\..\src\UI\Presenters\ResolutionCoordinator.psm1"
using module "..\..\src\Services\HostResolver.psm1"
using module "..\..\src\Models\LogLine.psm1"
using namespace System.Collections.Generic

# Captures the detail log lines the gate writes. The base ctor only stores its refs.
class FakeDetail : InventoryPresenter {
    [List[string]] $Lines = [List[string]]::new()
    FakeDetail() : base($null, $null, $null, $null, $null, $null, $null) {}
    [void] AppendLog([string]$hostName, [string]$text) { $this.Lines.Add($text) }
    [void] AppendLog([string]$hostName, [string]$text, [LogSeverity]$severity) { $this.Lines.Add($text) }
}

# Records the re-resolve an aborted apply asks for.
class FakeResolution : ResolutionCoordinator {
    [List[string]] $Invalidated = [List[string]]::new()
    FakeResolution() : base($null, $null, $null, $null, $null, $null) {}
    [void] InvalidateResolved([string]$hostName) { $this.Invalidated.Add($hostName) }
}

Describe "HomePresenter apply gate" {

    BeforeEach {
        $script:p = [System.Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject([HomePresenter])
        $script:p.Resolver = [HostResolver]::new($null, $null)
        $script:p.Detail = [FakeDetail]::new()
        $script:p.Resolution = [FakeResolution]::new()
        $script:p.PendingApplies = [HashSet[string]]::new()
        $script:p.PendingRuns = @{}
        $script:p.Rows = @{}
        $script:p.ScanSteps = @{}
        $script:p.Toasts = $null
        # StartApply has no UpdateService here, so its first log line is the proof it ran.
        $script:started = { @($script:p.Detail.Lines | Where-Object { $_ -like 'Confirmed. Phase 2*' }).Count }
    }

    It "waits when the check has not answered yet, and starts the apply on Match" {
        $script:p.GateApply('PC-1') | Should -BeFalse
        $script:p.PendingApplies.Contains('PC-1') | Should -BeTrue
        $script:p.Detail.Lines[-1] | Should -BeLike 'Waiting for the identity check*'
        (& $script:started) | Should -Be 0

        $script:p.Resolver.CacheName('PC-1', 'pc-1.corp.local')
        $script:p.OnIdentityVerdict('PC-1')

        $script:p.PendingApplies.Count | Should -Be 0
        (& $script:started) | Should -Be 1
    }

    It "drops a waiting apply when a different machine answers, and re-resolves the host" {
        $null = $script:p.GateApply('PC-1')
        $script:p.Resolver.CacheName('PC-1', 'OTHER-PC')

        $script:p.OnIdentityVerdict('PC-1')

        (& $script:started) | Should -Be 0
        $script:p.PendingApplies.Count | Should -Be 0
        $script:p.Detail.Lines[-1] | Should -BeLike "Apply aborted: that address answers as 'OTHER-PC'*"
        $script:p.Resolution.Invalidated | Should -Be @('PC-1')
    }

    It "drops a waiting apply when the machine gives no name at all (Failed is not Unknown)" {
        $null = $script:p.GateApply('PC-1')
        $script:p.Resolver.CacheName('PC-1', '')

        $script:p.OnIdentityVerdict('PC-1')

        (& $script:started) | Should -Be 0
        $script:p.Detail.Lines[-1] | Should -BeLike 'Apply not started: the machine at that address did not answer*'
        $script:p.Resolution.Invalidated | Should -Be @('PC-1')
    }

    It "starts straight away on a verdict that already landed, and never on Failed" {
        $script:p.Resolver.CacheName('PC-1', 'PC-1')
        $script:p.GateApply('PC-1') | Should -BeFalse   # StartApply itself fails without a service here
        (& $script:started) | Should -Be 1
        $script:p.PendingApplies.Count | Should -Be 0

        $script:p.Resolver.CacheName('PC-2', '')
        $script:p.GateApply('PC-2') | Should -BeFalse
        (& $script:started) | Should -Be 1
        $script:p.PendingApplies.Contains('PC-2') | Should -BeFalse
    }

    It "a verdict for a host with no waiting apply only refreshes the pill" {
        $script:p.Resolver.CacheName('PC-9', 'PC-9')
        { $script:p.OnIdentityVerdict('PC-9') } | Should -Not -Throw
        (& $script:started) | Should -Be 0
    }

    It "a check that could not run drops the waiting apply with a reason" {
        $null = $script:p.GateApply('PC-1')

        $script:p.DropPendingRunOnResolveFailure('PC-1')

        $script:p.PendingApplies.Count | Should -Be 0
        $script:p.Detail.Lines[-1] | Should -BeLike 'Apply not started: the identity check could not run*'
    }
}
