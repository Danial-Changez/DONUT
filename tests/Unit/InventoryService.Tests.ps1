using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\InventoryService.psm1"
using module "..\Helpers\MockNetworkProbe.psm1"
using namespace System.Net

Describe "InventoryService" {
    BeforeAll {
        $script:tempDir = Join-Path $TestDrive "Inventory"
        New-Item -Path $script:tempDir -ItemType Directory -Force | Out-Null
        $scriptsDir = Join-Path $script:tempDir "Scripts"
        New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $scriptsDir "RemoteWorker.ps1") -ItemType File -Force | Out-Null
        $script:reportsDir = Join-Path $script:tempDir "Reports"
        New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:config = [AppConfig]::new($script:tempDir, (Join-Path $script:tempDir "Logs"), $script:reportsDir, @{})
    }

    Context "PrepareInventory" {
        It "Returns worker args tagged Inventory" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())

            $result = $service.PrepareInventory("TestHost")

            $result.Arguments.HostName | Should -Be "TestHost"
            $result.Arguments.JobType  | Should -Be "Inventory"
        }

        It "Does NOT probe connectivity on the UI thread (the worker asserts it)" {
            # The worker checks reachability on the pool thread, so Prepare must not block.
            $probe = [MockNetworkProbe]::new()
            $probe.IsOnlineResult = $false
            $service = [InventoryService]::new($script:config, $probe)

            { $service.PrepareInventory("OfflineHost") } | Should -Not -Throw
        }
    }

    Context "ParseInventory" {
        It "Parses a valid inventory JSON into a MachineInventory" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())

            $json = @{
                model = 'Latitude 5340'; serviceTag = 'ABC1234'
                hasBattery = $true; designCapacity = 50000; fullChargeCapacity = 45000
                chargePercent = 72; charging = $true
                freeSpaceBytes = 42949672960; totalSpaceBytes = 274877906944
                lastBootTime = '2026-06-25T08:00:00Z'; probedAt = '2026-06-27T12:00:00Z'
            } | ConvertTo-Json
            Set-Content -Path (Join-Path $script:reportsDir "INVHOST-inventory.json") -Value $json

            $inv = $service.ParseInventory("INVHOST")

            $inv                    | Should -Not -BeNullOrEmpty
            $inv.Model              | Should -Be 'Latitude 5340'
            $inv.ServiceTag         | Should -Be 'ABC1234'
            $inv.FullChargeCapacity | Should -Be 45000
            $inv.ChargePercent      | Should -Be 72
            $inv.FreeSpaceBytes     | Should -Be 42949672960
        }

        It "Returns null when the inventory file is missing" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())
            $service.ParseInventory("NoSuchHost") | Should -BeNullOrEmpty
        }

        It "Returns null for malformed JSON" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())
            Set-Content -Path (Join-Path $script:reportsDir "BADJSON-inventory.json") -Value "{ not valid json"
            $service.ParseInventory("BADJSON") | Should -BeNullOrEmpty
        }
    }

    Context "DeleteReport" {
        It "Removes the host's inventory file and tolerates a missing one" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())
            $path = Join-Path $script:reportsDir "GONE-inventory.json"
            Set-Content -Path $path -Value '{}'

            # The second call proves a missing file is a no-op, not a throw.
            $service.DeleteReport("GONE")
            $service.DeleteReport("GONE")

            Test-Path $path | Should -BeFalse
        }
    }

}
