using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "DriverMatchingService" {
    Context "Initialization" {
        It "Should initialize with default brand patterns" {
            $service = [DriverMatchingService]::new()
            $service.BrandPatterns.Count | Should -BeGreaterThan 0
            $service.BrandPatterns["Dell"] | Should -Contain "Dell Inc."
        }

        It "Should initialize with category patterns" {
            $service = [DriverMatchingService]::new()
            $service.CategoryPatterns.Count | Should -BeGreaterThan 0
            $service.CategoryPatterns["BIOS"] | Should -Contain "BIOS"
        }

        It "Should default to a no-op logger when constructed without one" {
            $service = [DriverMatchingService]::new()
            $service.Logger | Should -Not -BeNullOrEmpty
        }

        It "Should accept an injected logger and still initialize patterns" {
            $logger = [CapturingLogService]::new()
            $service = [DriverMatchingService]::new($logger)

            $service.Logger | Should -Be $logger
            $service.BrandPatterns.Count | Should -BeGreaterThan 0
        }
    }

    Context "DetectBrand" {
        It "Should detect Dell brand" {
            $service = [DriverMatchingService]::new()
            $service.DetectBrand("Dell Inc.") | Should -Be "Dell"
        }

        It "Should return Unknown for unrecognized manufacturer" {
            $service = [DriverMatchingService]::new()
            $service.DetectBrand("SomeUnknownBrand") | Should -Be "Unknown"
        }
    }

    Context "DetectCategory" {
        It "Should detect BIOS category" {
            $service = [DriverMatchingService]::new()
            $service.DetectCategory("System BIOS Update") | Should -Be "BIOS"
        }

        It "Should detect Audio category" {
            $service = [DriverMatchingService]::new()
            $service.DetectCategory("Realtek Audio Driver") | Should -Be "Audio"
        }

        It "Should return Other for unrecognized category" {
            $service = [DriverMatchingService]::new()
            $service.DetectCategory("XYZ Special Tool") | Should -Be "Other"
        }
    }

    Context "FindBestDriverMatch" {
        It "Should return null for empty driver list" {
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch("SomeUpdate", @())
            $result | Should -BeNullOrEmpty
        }

        It "Should find matching driver by category" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                @{ DriverName = "Realtek Audio Device"; ProviderName = "Realtek"; DriverVersion = "1.0.0" }
                @{ DriverName = "Intel Network Adapter"; ProviderName = "Intel"; DriverVersion = "2.0.0" }
            )
            
            $result = $service.FindBestDriverMatch("Realtek Audio Driver Update", $drivers)
            $result | Should -Not -BeNullOrEmpty
            $result.Category | Should -Be "Audio"
        }
    }

    Context "CompareVersions" {
        It "Should detect newer version" {
            $service = [DriverMatchingService]::new()
            $result = $service.CompareVersions("1.0.0", "2.0.0")
            $result.IsNewer | Should -Be $true
        }

        It "Should detect same version" {
            $service = [DriverMatchingService]::new()
            $result = $service.CompareVersions("1.0.0", "1.0.0")
            $result.IsNewer | Should -Be $false
        }

        It "Should detect older version" {
            $service = [DriverMatchingService]::new()
            $result = $service.CompareVersions("2.0.0", "1.0.0")
            $result.IsNewer | Should -Be $false
        }
    }

}
