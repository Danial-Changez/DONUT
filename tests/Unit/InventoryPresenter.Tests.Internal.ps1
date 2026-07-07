# Unit tests for InventoryPresenter - requires WPF + Donut.Mvvm (loaded by the
# wrapper). Fakes the services + the HomePresenter back-ref so the detail render and
# re-probe decision are verified without WPF controls or a live runspace.
using module "..\..\src\UI\Presenters\InventoryPresenter.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Models\RecentConnection.psm1"
using module "..\..\src\Services\InventoryService.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Models\JobEnums.psm1"

# --- Test doubles -----------------------------------------------------------

# Overrides ParseInventory to return a script-set value (no report-file IO). The
# base InventoryService ctor only stores its refs, so base($null, $null) is safe.
class FakeInventoryService : InventoryService {
    [MachineInventory] $NextInventory
    FakeInventoryService() : base($null, $null) {}
    [MachineInventory] ParseInventory([string]$hostName) { return $this.NextInventory }
}

# Stands in for HostViewModel: records what the detail render pushes onto the row.
class FakeRow {
    [MachineInventory] $AppliedInventory
    [string] $ProbedIp = $null
    [int] $PendingUpdates = -1
    [void] ApplyInventory([MachineInventory]$inv) { $this.AppliedInventory = $inv }
    [void] SetProbed([string]$ip, [string]$iso) { $this.ProbedIp = $ip }
    [void] SetPendingUpdates([int]$count) { $this.PendingUpdates = $count }
    [void] ApplyFolders([object]$report) {}
}

# Records the inventory persisted by CompleteInventory.
class FakeStore {
    [hashtable] $Inventories = @{}
    [void] UpsertInventory([string]$h, [MachineInventory]$inv) { $this.Inventories[$h] = $inv }
    [void] UpsertDiskUsage([string]$h, [object]$r) {}
}

class FakeResolver {
    [string] GetCachedIp([string]$h) { return '10.0.0.9' }
}

# Duck-typed HomePresenter back-ref: only the seams InventoryPresenter reaches.
class FakeHome {
    [hashtable] $Rows = @{}
    [hashtable] $Records = @{}
    [string] $SelectedHost
    [object] $Resolver
    [int] $InvalidateCount = 0
    FakeHome() { $this.Resolver = [FakeResolver]::new() }
    [object] GetRecord([string]$h) {
        if ($this.Records.ContainsKey($h)) { return $this.Records[$h] } return $null
    }
    [object] GetRow([string]$h) {
        if ($this.Rows.ContainsKey($h)) { return $this.Rows[$h] } return $null
    }
    [void] InvalidateResolved([string]$h) { $this.InvalidateCount++ }
}

Describe "InventoryPresenter" {

    BeforeAll {
        # Builds a RecentConnection whose inventory was probed $probedMinutesAgo ago
        # (or never, when negative).
        function New-Record {
            param([int]$probedMinutesAgo = -1, [int]$updateCount = 0)
            $rc = [RecentConnection]::new()
            $rc.UpdateCount = $updateCount
            if ($probedMinutesAgo -ge 0) {
                $inv = [MachineInventory]::new()
                $inv.ProbedAt = [datetime]::UtcNow.AddMinutes(-$probedMinutesAgo).ToString('o')
                $rc.Inventory = $inv
            }
            return $rc
        }
    }

    BeforeEach {
        $script:fakeHome = [FakeHome]::new()
        $script:svc = [FakeInventoryService]::new()
        $script:store = [FakeStore]::new()
        $script:p = [InventoryPresenter]::new(
            $null, $null, $null, $script:svc, $null, $script:store, $null, $script:fakeHome)
    }

    Context "InventoryIsStale (re-probe decision)" {
        It "is stale when the host has no cached record" {
            $script:p.InventoryIsStale('PC1') | Should -BeTrue
        }
        It "is stale when the record has no inventory" {
            $script:fakeHome.Records['PC1'] = New-Record -probedMinutesAgo -1
            $script:p.InventoryIsStale('PC1') | Should -BeTrue
        }
        It "is stale when the last probe is older than the 3-minute TTL" {
            $script:fakeHome.Records['PC1'] = New-Record -probedMinutesAgo 10
            $script:p.InventoryIsStale('PC1') | Should -BeTrue
        }
        It "is fresh when the last probe is within the TTL" {
            $script:fakeHome.Records['PC1'] = New-Record -probedMinutesAgo 1
            $script:p.InventoryIsStale('PC1') | Should -BeFalse
        }
    }

    Context "CompleteInventory" {
        BeforeEach {
            $script:job = [AsyncJob]::new('PC1', [JobKind]::Inventory)
        }

        It "caches the inventory and populates the host row on success" {
            $script:fakeHome.Rows['PC1'] = [FakeRow]::new()
            $script:fakeHome.Records['PC1'] = New-Record -probedMinutesAgo -1 -updateCount 4
            $inv = [MachineInventory]::new()
            $inv.ProbedAt = [datetime]::UtcNow.ToString('o')
            $script:svc.NextInventory = $inv
            $script:job.Status = 'Completed'

            $script:p.CompleteInventory($script:job)

            $script:store.Inventories['PC1'] | Should -Be $inv           # persisted
            $script:fakeHome.Rows['PC1'].AppliedInventory | Should -Be $inv  # tile populated
            $script:fakeHome.Rows['PC1'].ProbedIp | Should -Be '10.0.0.9'
            $script:fakeHome.Rows['PC1'].PendingUpdates | Should -Be 4
        }

        It "drops the result when the card was cleared mid-probe" {
            # No row for PC1 -> treated as cleared: nothing persisted, no throw.
            $script:svc.NextInventory = [MachineInventory]::new()
            $script:job.Status = 'Completed'

            { $script:p.CompleteInventory($script:job) } | Should -Not -Throw
            $script:store.Inventories.ContainsKey('PC1') | Should -BeFalse
        }

        It "invalidates the cached resolution on a failed probe" {
            $script:fakeHome.Rows['PC1'] = [FakeRow]::new()
            $script:job.Status = 'Failed'

            $script:p.CompleteInventory($script:job)

            $script:fakeHome.InvalidateCount | Should -Be 1
            $script:store.Inventories.ContainsKey('PC1') | Should -BeFalse
        }
    }
}
