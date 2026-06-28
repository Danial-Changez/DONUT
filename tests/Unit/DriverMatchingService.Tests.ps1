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

        It "Should detect HP brand" {
            $service = [DriverMatchingService]::new()
            $service.DetectBrand("Hewlett-Packard") | Should -Be "HP"
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

    Context "CategoryMappings" {
        It "Should map Audio category correctly" {
            $service = [DriverMatchingService]::new()
            $service.CategoryMappings["Audio"] | Should -Contain "Audio"
            $service.CategoryMappings["Audio"] | Should -Contain "MEDIA"
        }

        It "Should map Network category with Docks/Stands" {
            $service = [DriverMatchingService]::new()
            $service.CategoryMappings["Network"] | Should -Contain "Network"
            $service.CategoryMappings["Network"] | Should -Contain "NET"
            $service.CategoryMappings["Network"] | Should -Contain "Docks/Stands"
        }

        It "Should map Video/Graphics category" {
            $service = [DriverMatchingService]::new()
            $service.CategoryMappings["Graphics"] | Should -Contain "Video"
            $service.CategoryMappings["Graphics"] | Should -Contain "DISPLAY"
        }
    }

    Context "DeviceClassMappings" {
        It "Should map Windows device classes to categories" {
            $service = [DriverMatchingService]::new()
            $service.DeviceClassMappings["MEDIA"] | Should -Be "Audio"
            $service.DeviceClassMappings["NET"] | Should -Be "Network"
            $service.DeviceClassMappings["DISPLAY"] | Should -Be "Graphics"
            $service.DeviceClassMappings["Bluetooth"] | Should -Be "Network"
        }
    }

    Context "MapReportCategory" {
        It "Should map DCU report categories to standard categories" {
            $service = [DriverMatchingService]::new()
            $service.MapReportCategory("MEDIA") | Should -Be "Audio"
            $service.MapReportCategory("NET") | Should -Be "Network"
            $service.MapReportCategory("DISPLAY") | Should -Be "Graphics"
            $service.MapReportCategory("Docks/Stands") | Should -Be "Network"
        }

        It "Should return Other for unknown categories" {
            $service = [DriverMatchingService]::new()
            $service.MapReportCategory("UnknownCategory") | Should -Be "Other"
        }
    }

    Context "NormalizeAppName" {
        It "Should strip Application suffix and normalize" {
            $service = [DriverMatchingService]::new()
            $service.NormalizeAppName("Dell Command Update Application") | Should -Be "dellcommandupdate"
            $service.NormalizeAppName("Dell Command Update") | Should -Be "dellcommandupdate"
        }

        It "Should handle empty strings" {
            $service = [DriverMatchingService]::new()
            $service.NormalizeAppName("") | Should -Be ""
            $service.NormalizeAppName($null) | Should -Be ""
        }
    }

    Context "MapDeviceClass" {
        It "Should map MEDIA device class to Audio" {
            $service = [DriverMatchingService]::new()
            $service.MapDeviceClass("MEDIA") | Should -Be "Audio"
        }

        It "Should map NET device class to Network" {
            $service = [DriverMatchingService]::new()
            $service.MapDeviceClass("NET") | Should -Be "Network"
        }

        It "Should map DISPLAY device class to Graphics" {
            $service = [DriverMatchingService]::new()
            $service.MapDeviceClass("DISPLAY") | Should -Be "Graphics"
        }

        It "Should map Bluetooth device class to Network" {
            $service = [DriverMatchingService]::new()
            $service.MapDeviceClass("Bluetooth") | Should -Be "Network"
        }

        It "Should return Other for unknown device class" {
            $service = [DriverMatchingService]::new()
            $service.MapDeviceClass("UnknownClass") | Should -Be "Other"
        }
    }

    Context "FormatMatchResult" {
        It "Should format match result with driver info" {
            $service = [DriverMatchingService]::new()
            $match = @{
                Driver = @{ DriverName = "Realtek Audio"; DriverVersion = "6.0.1.8000" }
                Category = "Audio"
                Brand = "Realtek"
                Score = 75
            }
            
            $result = $service.FormatMatchResult($match, "Realtek Audio Driver", "6.0.1.9000")
            
            $result | Should -BeLike "*Update: Realtek Audio Driver*"
            $result | Should -BeLike "*Matched Driver: Realtek Audio*"
            $result | Should -BeLike "*Category: Audio*"
            $result | Should -BeLike "*Brand: Realtek*"
            $result | Should -BeLike "*Match Score: 75*"
        }

        It "Should indicate NEWER when update version is higher" {
            $service = [DriverMatchingService]::new()
            $match = @{
                Driver = @{ DriverName = "Realtek Audio"; DriverVersion = "1.0.0" }
                Category = "Audio"
                Brand = "Realtek"
                Score = 75
            }
            
            $result = $service.FormatMatchResult($match, "Realtek Audio Driver", "2.0.0")
            
            $result | Should -BeLike "*[NEWER]*"
        }

        It "Should indicate SAME/OLDER when update version is not higher" {
            $service = [DriverMatchingService]::new()
            $match = @{
                Driver = @{ DriverName = "Realtek Audio"; DriverVersion = "2.0.0" }
                Category = "Audio"
                Brand = "Realtek"
                Score = 75
            }
            
            $result = $service.FormatMatchResult($match, "Realtek Audio Driver", "1.0.0")
            
            $result | Should -BeLike "*[SAME/OLDER]*"
        }

        It "Should handle null match" {
            $service = [DriverMatchingService]::new()
            
            $result = $service.FormatMatchResult($null, "SomeDriver", "1.0.0")
            
            $result | Should -BeLike "*No matching installed driver found*"
        }
    }

}
