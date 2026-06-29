using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\InventoryService.psm1"
using namespace System.Net

# Same fake probe used by RemoteServices.Tests: connectivity without real network.
class MockNetworkProbe : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [IPAddress] $ResolveHostResult = [IPAddress]::Parse("127.0.0.1")

    MockNetworkProbe() {}

    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [IPAddress] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
}

Describe "InventoryService" {
    BeforeAll {
        $script:tempDir = Join-Path $env:TEMP "DonutTests_Inventory_$(Get-Random)"
        New-Item -Path $script:tempDir -ItemType Directory -Force | Out-Null
        $scriptsDir = Join-Path $script:tempDir "Scripts"
        New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $scriptsDir "RemoteWorker.ps1") -ItemType File -Force | Out-Null
        $script:reportsDir = Join-Path $script:tempDir "Reports"
        New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:config = [AppConfig]::new($script:tempDir, (Join-Path $script:tempDir "Logs"), $script:reportsDir, @{})
    }

    AfterAll {
        Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "BuildProbeScript" {
        It "Targets only -Property on the battery classes (bypasses the CIM serialization crash)" {
            $script = [InventoryService]::BuildProbeScript("TestHost")
            # Selecting a single property avoids serializing BatteryStaticData's
            # corrupt datetime field, which crashes a full Get-CimInstance pull.
            $script | Should -BeLike "*BatteryStaticData -Property DesignedCapacity*"
            $script | Should -BeLike "*BatteryFullChargedCapacity -Property FullChargedCapacity*"
            # Stays on the modern CIM cmdlet, not the removed Get-WmiObject.
            $script | Should -Not -BeLike '*Get-WmiObject*'
        }
    }

    Context "PrepareInventory" {
        It "Returns worker args tagged Inventory with a probe script" {
            $service = [InventoryService]::new($script:config, [MockNetworkProbe]::new())

            $result = $service.PrepareInventory("TestHost")

            $result.Arguments.HostName | Should -Be "TestHost"
            $result.Arguments.JobType  | Should -Be "Inventory"
            $result.Arguments.Options.ScriptText | Should -Not -BeNullOrEmpty
        }

        It "Does NOT probe connectivity on the UI thread (the worker asserts it)" {
            # Selecting an offline machine must not block/throw in Prepare*; the
            # worker checks reachability on the runspace-pool thread.
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

    Context "BuildProbeScript" {
        It "Embeds the host filename and key WMI/CIM classes, with no placeholder left" {
            $probeScript = [InventoryService]::BuildProbeScript("WSID-9")

            $probeScript | Should -BeLike "*WSID-9-inventory.json*"
            $probeScript | Should -BeLike "*BatteryFullChargedCapacity*"
            $probeScript | Should -BeLike "*Win32_ComputerSystem*"
            $probeScript | Should -Not -BeLike "*__HOST__*"
        }
    }
}
