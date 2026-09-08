# The wrapper loads WPF and Donut.Mvvm. Fakes replace the services and the HomePresenter.
using module "..\..\src\UI\Presenters\InventoryPresenter.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\InventoryService.psm1"
using module "..\..\src\Core\AsyncJob.psm1"
using module "..\..\src\Models\JobEnums.psm1"

# --- Test doubles -----------------------------------------------------------

# Returns a script-set inventory with no report-file IO, and counts calls so the session
# memo is verifiable. The base ctor only stores its refs, so base($null, $null) is safe.
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
            $second = $script:p.GetInventory('pc1')   # Case-insensitive key.

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
            $script:fakeHome.Rows['PC1'].AppliedInventory | Should -Be $inv
            $script:fakeHome.Rows['PC1'].ProbedIp | Should -Be '10.0.0.9'
        }

        It "drops the result when the card was cleared mid-probe" {
            # No row for PC1 means cleared: nothing memoized, no throw.
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

Describe "InventoryPresenter.ProfileWarning" {

    # A profile folder is a person's data, so the confirmation says so before Clear.
    BeforeAll {
        $script:Temp = [pscustomobject]@{ Path = 'C:\Windows\Temp\'; IsUserDir = $false }
        $script:One = [pscustomobject]@{ Path = 'C:\Users\CE813191\'; IsUserDir = $true }
        $script:Two = [pscustomobject]@{ Path = 'C:\Users\eg23444\'; IsUserDir = $true }
    }

    It "stays silent when nothing selected is a profile" {
        [InventoryPresenter]::ProfileWarning(@($script:Temp)) | Should-Be ''
    }

    It "states the hazard once when a profile is checked" {
        [InventoryPresenter]::ProfileWarning(@($script:One)) |
            Should-Be 'Warning: You are deleting a user profile'
    }

    It "says the same thing for several, since each row is marked itself" {
        [InventoryPresenter]::ProfileWarning(@($script:Temp, $script:One, $script:Two)) |
            Should-Be 'Warning: You are deleting a user profile'
    }

    It "fires on a profile buried among ordinary folders" {
        ([InventoryPresenter]::ProfileWarning(@($script:Temp, $script:One)).Length -gt 0) |
            Should-BeTrue
    }
}

Describe "InventoryPresenter.RemoveHostLog" {

    # Clearing a machine takes its on-disk log too: the buffer is only this session's copy.
    BeforeEach {
        $script:logs = Join-Path $TestDrive ('logs-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $script:logs -Force
        foreach ($n in 'TPS5330AP.log', 'OTHER-PC.log', 'Donut.log') {
            Set-Content -LiteralPath (Join-Path $script:logs $n) -Value 'x'
        }
        $cfg = [AppConfig]::new('C:\Src', $script:logs, 'C:\Reports', @{})
        $script:logP = [InventoryPresenter]::new(
            $cfg, $null, $null, [FakeInventoryService]::new(), $null, $null, [FakeHome]::new())
    }

    It "deletes that machine's log and leaves the others" {
        $script:logP.RemoveHostLog('TPS5330AP')

        (Test-Path (Join-Path $script:logs 'TPS5330AP.log')) | Should-BeFalse
        (Test-Path (Join-Path $script:logs 'OTHER-PC.log')) | Should-BeTrue
        (Test-Path (Join-Path $script:logs 'Donut.log')) | Should-BeTrue
    }

    It "is quiet when the machine never wrote one" {
        { $script:logP.RemoveHostLog('NEVER-RAN') } | Should-NotThrow
    }
}
