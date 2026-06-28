using module "..\..\src\Services\SystemInfoService.psm1"

Describe "SystemInfoService" {

    Context "BatteryLabel" {
        It "Shows charge and charging state when a battery is present" {
            [SystemInfoService]::BatteryLabel($true, 76, $true) | Should -Be '76% - charging'
        }

        It "Shows 'on battery' when discharging" {
            [SystemInfoService]::BatteryLabel($true, 42, $false) | Should -Be '42% - on battery'
        }

        It "Shows an AC label when there is no battery" {
            [SystemInfoService]::BatteryLabel($false, -1, $false) | Should -Be 'AC - no battery'
        }
    }
}
