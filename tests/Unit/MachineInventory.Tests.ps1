using module "..\..\src\Models\MachineInventory.psm1"

Describe "InventoryFormat" {
    Context "BatteryHealthPercent" {
        It "Computes health as full-charge over design" {
            [InventoryFormat]::BatteryHealthPercent(50000, 45000) | Should -Be 90
        }
        It "Clamps above 100 when full charge exceeds design" {
            [InventoryFormat]::BatteryHealthPercent(50000, 55000) | Should -Be 100
        }
        It "Returns -1 when design capacity is zero/unknown" {
            [InventoryFormat]::BatteryHealthPercent(0, 45000) | Should -Be -1
        }
        It "Returns -1 when full-charge capacity is missing" {
            [InventoryFormat]::BatteryHealthPercent(50000, 0) | Should -Be -1
        }
    }

    Context "BatteryHealthLabel" {
        It "Reports no battery for desktops" {
            [InventoryFormat]::BatteryHealthLabel($false, -1, -1) | Should -BeLike '*No battery*'
        }
        It "Reports no-data when health is unknown" {
            [InventoryFormat]::BatteryHealthLabel($true, -1, -1) | Should -BeLike '*no battery data*'
        }
        It "Includes cycles when available" {
            [InventoryFormat]::BatteryHealthLabel($true, 88, 412) | Should -Be '88% health · 412 cycles'
        }
        It "Omits cycles when unavailable (-1)" {
            [InventoryFormat]::BatteryHealthLabel($true, 88, -1) | Should -Be '88% health'
        }
    }

    Context "DiskFreeLabel" {
        It "Formats free/total in GB" {
            [InventoryFormat]::DiskFreeLabel(42949672960, 274877906944) | Should -Be '40 GB free of 256 GB'
        }
        It "Returns a dash when total is unknown" {
            [InventoryFormat]::DiskFreeLabel(0, 0) | Should -Be '—'
        }
    }

    Context "UptimeLabel" {
        It "Returns a dash for an unknown boot time" {
            [InventoryFormat]::UptimeLabel([datetime]::MinValue) | Should -Be '—'
        }
        It "Phrases multi-day uptime" {
            [InventoryFormat]::UptimeLabel([datetime]::UtcNow.AddDays(-3)) | Should -BeLike 'up 3 day*'
        }
        It "Phrases hours uptime" {
            [InventoryFormat]::UptimeLabel([datetime]::UtcNow.AddHours(-5)) | Should -BeLike 'up 5 hr*'
        }
    }
}

Describe "MachineInventory" {
    Context "FromHashtable" {
        It "Builds a populated inventory from a full hashtable" {
            $h = @{
                model = 'Latitude 5340'; serviceTag = 'ABC1234'; biosVersion = '1.18.0'
                hasBattery = $true; designCapacity = 50000; fullChargeCapacity = 45000
                cycleCount = 120; chargePercent = 67; charging = $false
                freeSpaceBytes = 42949672960; totalSpaceBytes = 274877906944
                lastBootTime = '2026-06-25T08:00:00Z'; probedAt = '2026-06-27T12:00:00Z'
            }
            $mi = [MachineInventory]::FromHashtable($h)
            $mi.Model              | Should -Be 'Latitude 5340'
            $mi.ServiceTag         | Should -Be 'ABC1234'
            $mi.HasBattery         | Should -Be $true
            $mi.DesignCapacity     | Should -Be 50000
            $mi.FullChargeCapacity | Should -Be 45000
            $mi.CycleCount         | Should -Be 120
            $mi.ChargePercent      | Should -Be 67
            $mi.FreeSpaceBytes     | Should -Be 42949672960
        }
        It "Defaults cycle count to -1 when absent (desktop)" {
            $mi = [MachineInventory]::FromHashtable(@{ model = 'OptiPlex 7010'; hasBattery = $false })
            $mi.CycleCount | Should -Be -1
            $mi.HasBattery | Should -Be $false
            $mi.Model      | Should -Be 'OptiPlex 7010'
        }
        It "Returns an empty inventory for a null hashtable" {
            $mi = [MachineInventory]::FromHashtable($null)
            $mi.Model      | Should -Be ''
            $mi.CycleCount | Should -Be -1
        }
    }
}
