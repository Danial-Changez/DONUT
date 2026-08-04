# Unit tests for InventoryPresenter - requires WPF + Donut.Mvvm (loaded by the
# wrapper). Fakes the services + the HomePresenter back-ref so the detail render,
# the report-file memo, and the re-probe decision are verified without WPF
# controls or a live runspace.
using module "..\..\src\UI\Presenters\InventoryPresenter.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Services\InventoryService.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Models\JobEnums.psm1"

# --- Test doubles -----------------------------------------------------------

# Overrides ParseInventory to return a script-set value (no report-file IO) and
# counts the calls so the session memo is verifiable. The base InventoryService
# ctor only stores its refs, so base($null, $null) is safe.
class FakeInventoryService : InventoryService {
    [MachineInventory] $NextInventory
    [int] $ParseCalls = 0
    FakeInventoryService() : base($null, $null) {}
    [MachineInventory] ParseInventory([string]$hostName) {
        $this.ParseCalls++
        return $this.NextInventory
    }
}

# Stands in for HostViewModel: records what the detail render pushes onto the row.
class FakeRow {
    [MachineInventory] $AppliedInventory
    [string] $ProbedIp = $null
    [void] ApplyInventory([MachineInventory]$inv) { $this.AppliedInventory = $inv }
    [void] SetResolvedIp([string]$ip) { $this.ProbedIp = $ip }
    [void] ApplyFolders([object]$report) {}
}

class FakeResolver {
    [string] GetCachedIp([string]$h) { return '10.0.0.9' }
}

# ResolutionCoordinator seam: InventoryPresenter reaches resolution via Home.Resolution.
class FakeResolution {
    [int] $InvalidateCount = 0
    [void] InvalidateResolved([string]$h) { $this.InvalidateCount++ }
    [void] PrefetchIp([string]$h) {}
}

# Duck-typed HomePresenter back-ref: only the seams InventoryPresenter reaches.
class FakeHome {
    [hashtable] $Rows = @{}
    [string] $SelectedHost
    [object] $Resolver
    [object] $Resolution
    FakeHome() {
        $this.Resolver = [FakeResolver]::new()
        $this.Resolution = [FakeResolution]::new()
    }
    [object] GetRow([string]$h) {
        if ($this.Rows.ContainsKey($h)) { return $this.Rows[$h] } return $null
    }
}

Describe "InventoryPresenter" {

    BeforeAll {
        # Builds an inventory whose probe ran $probedMinutesAgo ago.
        function New-Inventory {
            param([int]$probedMinutesAgo = 0)
            $inv = [MachineInventory]::new()
            $inv.ProbedAt = [datetime]::UtcNow.AddMinutes(-$probedMinutesAgo).ToString('o')
            return $inv
        }
    }

    BeforeEach {
        $script:fakeHome = [FakeHome]::new()
        $script:svc = [FakeInventoryService]::new()
        $script:p = [InventoryPresenter]::new(
            $null, $null, $null, $script:svc, $null, $null, $script:fakeHome)
    }

    Context "GetInventory (session memo over the reports\ JSON)" {
        It "parses the report file once and reuses the instance" {
            $script:svc.NextInventory = New-Inventory

            $first = $script:p.GetInventory('PC1')
            $second = $script:p.GetInventory('pc1')   # case-insensitive key

            $script:svc.ParseCalls | Should -Be 1
            $second | Should -Be $first
        }

        It "does not cache a missing report, so a later probe is picked up" {
            $script:svc.NextInventory = $null
            $script:p.GetInventory('PC1') | Should -BeNullOrEmpty

            $script:svc.NextInventory = New-Inventory
            $script:p.GetInventory('PC1') | Should -Not -BeNullOrEmpty
        }
    }

    Context "InventoryIsStale (re-probe decision)" {
        It "is stale when the host has no report file" {
            $script:svc.NextInventory = $null
            $script:p.InventoryIsStale('PC1') | Should -BeTrue
        }
        It "is stale when the last probe is older than the 3-minute TTL" {
            $script:svc.NextInventory = New-Inventory -probedMinutesAgo 10
            $script:p.InventoryIsStale('PC1') | Should -BeTrue
        }
        It "is fresh when the last probe is within the TTL" {
            $script:svc.NextInventory = New-Inventory -probedMinutesAgo 1
            $script:p.InventoryIsStale('PC1') | Should -BeFalse
        }
    }

    Context "CompleteInventory" {
        BeforeEach {
            $script:job = [AsyncJob]::new('PC1', [JobKind]::Inventory)
        }

        It "memoizes the inventory and populates the host row on success" {
            $script:fakeHome.Rows['PC1'] = [FakeRow]::new()
            $inv = New-Inventory
            $script:svc.NextInventory = $inv
            $script:job.Status = 'Completed'

            $script:p.CompleteInventory($script:job)

            # The memo now serves the fresh probe without re-reading the file.
            $script:svc.NextInventory = $null
            $script:p.GetInventory('PC1') | Should -Be $inv
            $script:fakeHome.Rows['PC1'].AppliedInventory | Should -Be $inv  # tile populated
            $script:fakeHome.Rows['PC1'].ProbedIp | Should -Be '10.0.0.9'
        }

        It "drops the result when the card was cleared mid-probe" {
            # No row for PC1 -> treated as cleared: nothing memoized, no throw.
            $script:svc.NextInventory = New-Inventory
            $script:job.Status = 'Completed'

            { $script:p.CompleteInventory($script:job) } | Should -Not -Throw
            $script:svc.ParseCalls | Should -Be 0
        }

        It "invalidates the cached resolution on a failed probe" {
            $script:fakeHome.Rows['PC1'] = [FakeRow]::new()
            $script:job.Status = 'Failed'

            $script:p.CompleteInventory($script:job)

            $script:fakeHome.Resolution.InvalidateCount | Should -Be 1
            $script:svc.ParseCalls | Should -Be 0
        }
    }
}
