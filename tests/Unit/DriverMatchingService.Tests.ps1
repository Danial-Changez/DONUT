using module "..\..\src\Services\DriverMatchingService.psm1"

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

    Context "CategoryBrands (Legacy Patterns)" {
        It "Should have Audio brand patterns" {
            $service = [DriverMatchingService]::new()
            $service.CategoryBrands["Audio"] | Should -Contain "Realtek"
            $service.CategoryBrands["Audio"] | Should -Contain "Intel"
            $service.CategoryBrands["Audio"] | Should -Contain "Conexant"
            $service.CategoryBrands["Audio"] | Should -Contain "SoundMAX"
        }

        It "Should have Network brand patterns including Bluetooth" {
            $service = [DriverMatchingService]::new()
            $service.CategoryBrands["Network"] | Should -Contain "Realtek"
            $service.CategoryBrands["Network"] | Should -Contain "Broadcom"
            $service.CategoryBrands["Network"] | Should -Contain "Killer"
            $service.CategoryBrands["Network"] | Should -Contain "Bluetooth"
            $service.CategoryBrands["Network"] | Should -Contain "Ethernet"
        }

        It "Should have Video brand patterns" {
            $service = [DriverMatchingService]::new()
            $service.CategoryBrands["Video"] | Should -Contain "NVIDIA"
            $service.CategoryBrands["Video"] | Should -Contain "AMD"
            $service.CategoryBrands["Video"] | Should -Contain "Intel"
            $service.CategoryBrands["Video"] | Should -Contain "GeForce"
            $service.CategoryBrands["Video"] | Should -Contain "Radeon"
            $service.CategoryBrands["Video"] | Should -Contain "Iris"
        }
    }

    Context "DetectCategoryBrand" {
        It "Should detect Realtek for Audio updates" {
            $service = [DriverMatchingService]::new()
            $brand = $service.DetectCategoryBrand("Realtek High Definition Audio Driver", "Audio")
            $brand | Should -Be "Realtek"
        }

        It "Should detect Intel for Network updates" {
            $service = [DriverMatchingService]::new()
            $brand = $service.DetectCategoryBrand("Intel Dual Band Wireless AC 8265", "Network")
            $brand | Should -Be "Intel"
        }

        It "Should detect NVIDIA for Video updates" {
            $service = [DriverMatchingService]::new()
            $brand = $service.DetectCategoryBrand("NVIDIA GeForce GTX 1660", "Video")
            $brand | Should -Be "NVIDIA"
        }

        It "Should return null for unrecognized brand" {
            $service = [DriverMatchingService]::new()
            $brand = $service.DetectCategoryBrand("Unknown XYZ Driver", "Audio")
            $brand | Should -BeNullOrEmpty
        }
    }

    Context "FindBestDriverMatchByCategory" {
        It "Should match drivers by category brand" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                [PSCustomObject]@{ DeviceName = "Realtek High Definition Audio"; DriverVersion = "6.0.1.8045" }
                [PSCustomObject]@{ DeviceName = "Intel Ethernet Connection I219-V"; DriverVersion = "12.18.9.10" }
            )
            
            $result = $service.FindBestDriverMatchByCategory("Realtek Audio Driver 6.0.1.9000", $drivers, "Audio")
            $result | Should -Not -BeNullOrEmpty
            $result.Brand | Should -Be "Realtek"
            $result.DeviceName | Should -Match "Realtek"
        }

        It "Should handle Bluetooth matching in Network category" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                [PSCustomObject]@{ DeviceName = "Intel Wireless Bluetooth"; DriverVersion = "21.90.0.4" }
                [PSCustomObject]@{ DeviceName = "Intel Ethernet Connection"; DriverVersion = "12.0.0.0" }
            )
            
            $result = $service.FindBestDriverMatchByCategory("Intel Wireless Bluetooth Driver", $drivers, "Network")
            $result | Should -Not -BeNullOrEmpty
            $result.DeviceName | Should -Match "Bluetooth"
        }

        It "Should return null when no brand match found" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                [PSCustomObject]@{ DeviceName = "Realtek Audio"; DriverVersion = "1.0.0" }
            )
            
            $result = $service.FindBestDriverMatchByCategory("NVIDIA Graphics Driver", $drivers, "Audio")
            $result | Should -BeNullOrEmpty
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

    Context "GetSupportedCategories" {
        It "Should return all DCU supported categories" {
            $service = [DriverMatchingService]::new()
            $categories = $service.GetSupportedCategories()
            $categories | Should -Contain "Audio"
            $categories | Should -Contain "Video"
            $categories | Should -Contain "Network"
            $categories | Should -Contain "Storage"
            $categories | Should -Contain "Chipset"
            $categories | Should -Contain "BIOS"
            $categories | Should -Contain "Application"
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

    Context "SupportsCategoryBrandMatching" {
        It "Should return true for Audio category" {
            $service = [DriverMatchingService]::new()
            $service.SupportsCategoryBrandMatching("Audio") | Should -Be $true
        }

        It "Should return true for Network category" {
            $service = [DriverMatchingService]::new()
            $service.SupportsCategoryBrandMatching("Network") | Should -Be $true
        }

        It "Should return true for Video category" {
            $service = [DriverMatchingService]::new()
            $service.SupportsCategoryBrandMatching("Video") | Should -Be $true
        }

        It "Should return false for unsupported category" {
            $service = [DriverMatchingService]::new()
            $service.SupportsCategoryBrandMatching("UnsupportedCategory") | Should -Be $false
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

    Context "FilterDriversByVersion" {
        It "Should return empty array when drivers is empty" {
            $service = [DriverMatchingService]::new()
            $result = $service.FilterDriversByVersion(@(), @(@{ name = "Test"; version = "1.0"; category = "Audio" }), "Audio")
            $result.Count | Should -Be 0
        }

        It "Should return empty array when updates is empty" {
            $service = [DriverMatchingService]::new()
            $drivers = @([PSCustomObject]@{ DeviceName = "Realtek Audio"; DriverVersion = "1.0.0" })
            $result = $service.FilterDriversByVersion($drivers, @(), "Audio")
            $result.Count | Should -Be 0
        }

        It "Should filter drivers with matching updates by category" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                [PSCustomObject]@{ DeviceName = "Realtek High Definition Audio"; DriverVersion = "6.0.1.8000" }
                [PSCustomObject]@{ DeviceName = "Intel Ethernet"; DriverVersion = "12.0.0.0" }
            )
            $updates = @(
                [PSCustomObject]@{ name = "Realtek Audio Driver"; version = "6.0.1.9000"; category = "Audio" }
            )
            
            $result = $service.FilterDriversByVersion($drivers, $updates, "Audio")
            
            $result | Should -Not -BeNullOrEmpty
            $result[0].DeviceName | Should -Match "Realtek"
        }

        It "Should skip drivers with Unknown version" {
            $service = [DriverMatchingService]::new()
            $drivers = @(
                [PSCustomObject]@{ DeviceName = "Realtek Audio"; DriverVersion = "Unknown" }
            )
            $updates = @(
                [PSCustomObject]@{ name = "Realtek Audio Driver"; version = "6.0.1.9000"; category = "Audio" }
            )
            
            $result = $service.FilterDriversByVersion($drivers, $updates, "Audio")
            
            $result.Count | Should -Be 0
        }
    }

    Context "FilterApplicationsByVersion" {
        It "Should return empty array when applications is empty" {
            $service = [DriverMatchingService]::new()
            $result = $service.FilterApplicationsByVersion(@(), @(@{ name = "Dell Command Update"; category = "Application" }))
            $result.Count | Should -Be 0
        }

        It "Should return empty array when updates is empty" {
            $service = [DriverMatchingService]::new()
            $apps = @([PSCustomObject]@{ Name = "Dell Command Update"; Version = "4.0.0" })
            $result = $service.FilterApplicationsByVersion($apps, @())
            $result.Count | Should -Be 0
        }

        It "Should filter applications matching update names" {
            $service = [DriverMatchingService]::new()
            $apps = @(
                [PSCustomObject]@{ Name = "Dell Command Update"; Version = "4.0.0" }
                [PSCustomObject]@{ Name = "Other App"; Version = "1.0.0" }
            )
            $updates = @(
                [PSCustomObject]@{ name = "Dell Command Update Application"; version = "4.5.0"; category = "Application" }
            )
            
            $result = $service.FilterApplicationsByVersion($apps, $updates)
            
            $result | Should -Not -BeNullOrEmpty
            $result[0].Name | Should -Be "Dell Command Update"
        }

        It "Should skip applications with Unknown version" {
            $service = [DriverMatchingService]::new()
            $apps = @(
                [PSCustomObject]@{ Name = "Dell Command Update"; Version = "Unknown" }
            )
            $updates = @(
                [PSCustomObject]@{ name = "Dell Command Update Application"; version = "4.5.0"; category = "Application" }
            )
            
            $result = $service.FilterApplicationsByVersion($apps, $updates)
            
            $result.Count | Should -Be 0
        }

        It "Should return empty array when no Application category updates exist" {
            $service = [DriverMatchingService]::new()
            $apps = @(
                [PSCustomObject]@{ Name = "Dell Command Update"; Version = "4.0.0" }
            )
            $updates = @(
                [PSCustomObject]@{ name = "Realtek Audio Driver"; version = "6.0.0"; category = "Audio" }
            )
            
            $result = $service.FilterApplicationsByVersion($apps, $updates)
            
            $result.Count | Should -Be 0
        }
    }
}
