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
        BeforeAll {
            # The shape a scan-enriched report yields, BIOS row and inbox driver included.
            $script:drivers = @(
                @{ DriverName = "Realtek Audio Device"; ProviderName = "Realtek"; DriverVersion = "1.0.0" }
                @{ DriverName = "Intel Network Adapter"; ProviderName = "Intel"; DriverVersion = "2.0.0" }
                @{ DriverName = "Microsoft Bluetooth LE Enumerator"; ProviderName = "Microsoft"
                    DriverVersion = "10.0.26100.8972"
                }
                @{ DriverName = "Dell System BIOS"; ProviderName = "Dell Inc."; DriverVersion = "1.36.0" }
            )
        }

        It "Should return null for empty driver list" {
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch("SomeUpdate", "Driver", "", @())
            $result | Should -BeNullOrEmpty
        }

        It "Should find matching driver by category" {
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch("Realtek Audio Driver Update", "Driver", "Audio", $script:drivers)
            $result | Should -Not -BeNullOrEmpty
            $result.Category | Should -Be "Audio"
            $result.Driver.DriverName | Should -Be "Realtek Audio Device"
        }

        It "Never hands an application update a driver baseline" {
            # Field regression: SupportAssist once matched the BIOS row on brand alone.
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch(
                "Dell SupportAssist OS Recovery Plugin", "Application", "", $script:drivers)
            $result | Should -BeNullOrEmpty
        }

        It "Keeps short patterns like ME from hitting inside longer words" {
            # Field regression: the ME installer once matched a Bluetooth enumerator.
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch(
                "Intel Management Engine Components Installer", "Driver", "Chipset", $script:drivers)
            $result | Should -BeNullOrEmpty
        }

        It "Pairs a BIOS update with the scan's BIOS row exactly" {
            $service = [DriverMatchingService]::new()
            $result = $service.FindBestDriverMatch(
                "Dell Latitude 5330 System BIOS", "BIOS", "BIOS", $script:drivers)
            $result.Driver.DriverVersion | Should -Be "1.36.0"
            $result.Category | Should -Be "BIOS"
        }

        It "Rejects same-category rows that share no name word" {
            $service = [DriverMatchingService]::new()
            $drivers = @(@{ DriverName = "WAN Miniport (IKEv2)"; ProviderName = "Microsoft"
                    DriverVersion = "1.0"; DeviceClass = "NET"
            })
            $result = $service.FindBestDriverMatch("Intel Killer Wireless Driver", "Driver", "Network", $drivers)
            $result | Should -BeNullOrEmpty
        }

        It "Uses the recorded device class over name sniffing" {
            $service = [DriverMatchingService]::new()
            # The name alone reads as no category, but the scan recorded MEDIA.
            $drivers = @(@{ DriverName = "Intel(R) SST OED"; ProviderName = "Intel"
                    DriverVersion = "10.29.0.1"; DeviceClass = "MEDIA"
            })
            $result = $service.FindBestDriverMatch("Intel Smart Sound Technology Driver", "Driver", "Audio", $drivers)
            $result | Should -Not -BeNullOrEmpty
            $result.Driver.DriverName | Should -Be "Intel(R) SST OED"
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
