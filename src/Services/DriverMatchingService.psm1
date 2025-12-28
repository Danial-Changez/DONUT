class DriverMatchingService {
    [hashtable] $BrandPatterns
    [hashtable] $CategoryPatterns
    [hashtable] $CategoryBrands
    [hashtable] $CategoryMappings
    [hashtable] $DeviceClassMappings

    DriverMatchingService() {
        # Brand patterns for manufacturer detection (OEM/Component makers)
        $this.BrandPatterns = @{
            "Dell"      = @("Dell Inc.", "Dell", "DELL")
            "HP"        = @("Hewlett-Packard", "HP", "HP Inc.", "Hewlett Packard")
            "Lenovo"    = @("Lenovo", "LENOVO")
            "Microsoft" = @("Microsoft Corporation", "Microsoft", "Surface")
            "Asus"      = @("ASUSTeK", "ASUS", "ASUSTek Computer")
            "Acer"      = @("Acer", "Acer Inc.", "Gateway")
            "Toshiba"   = @("Toshiba", "TOSHIBA")
            "Samsung"   = @("Samsung", "SAMSUNG ELECTRONICS")
            "Intel"     = @("Intel", "Intel Corporation", "Intel Corp")
            "AMD"       = @("AMD", "Advanced Micro Devices")
            "Nvidia"    = @("NVIDIA", "Nvidia Corporation")
            "Realtek"   = @("Realtek", "Realtek Semiconductor")
        }
        
        # Legacy brand patterns by category (from main branch)
        # Used for matching updates to installed drivers by component type
        $this.CategoryBrands = @{
            "Audio"   = @("Realtek", "Intel", "AMD", "NVIDIA", "Conexant", "IDT", "VIA", "Creative", "SoundMAX")
            "Network" = @("Realtek", "Intel", "Broadcom", "Qualcomm", "Marvell", "Killer", "MediaTek", "Ralink", "Microsoft", "Bluetooth", "USB", "GbE", "Ethernet")
            "Video"   = @("NVIDIA", "AMD", "Intel", "ATI", "Radeon", "GeForce", "UHD", "Iris", "Xe")
        }
        
        # Category patterns for detecting update/driver categories
        $this.CategoryPatterns = @{
            "BIOS"        = @("BIOS", "System BIOS", "UEFI", "Firmware")
            "Chipset"     = @("Chipset", "Intel Management Engine", "ME", "AMT")
            "Audio"       = @("Audio", "Sound", "Realtek Audio", "High Definition Audio", "MEDIA")
            "Network"     = @("Network", "Ethernet", "WiFi", "Wireless", "LAN", "WLAN", "Intel Dual Band", "NET", "Docks/Stands")
            "Graphics"    = @("Graphics", "Display", "Video", "VGA", "Intel HD", "Intel UHD", "GeForce", "Radeon", "DISPLAY")
            "Storage"     = @("Storage", "RAID", "AHCI", "NVMe", "SSD", "Intel RST")
            "USB"         = @("USB", "USB Controller", "USB 3.0", "USB-C")
            "Bluetooth"   = @("Bluetooth", "BT")
            "Camera"      = @("Camera", "Webcam", "IR Camera", "Integrated Camera")
            "Touchpad"    = @("Touchpad", "Trackpad", "Mouse", "Pointing Device", "Input")
            "Thunderbolt" = @("Thunderbolt", "TB3", "TB4")
            "Application" = @("Application", "App")
            "Others"      = @("Others", "Other")
        }
        
        # Category name mappings (DCU report category -> standard category)
        # Used when parsing Dell Command Update XML reports
        $this.CategoryMappings = @{
            "Audio"       = @("Audio", "MEDIA")
            "Network"     = @("Network", "NET", "Docks/Stands")
            "Graphics"    = @("Video", "DISPLAY", "Graphics")
            "Application" = @("Application")
            "BIOS"        = @("BIOS")
            "Chipset"     = @("Chipset")
            "Storage"     = @("Storage")
            "Input"       = @("Input")
            "Others"      = @("Others")
        }
        
        # Windows Device Class to category mappings
        # Used when reading installed drivers via Win32_PnPSignedDriver
        $this.DeviceClassMappings = @{
            "MEDIA"     = "Audio"
            "NET"       = "Network"
            "NETWORK"   = "Network"
            "Bluetooth" = "Network"
            "DISPLAY"   = "Graphics"
        }
    }

    [string] DetectBrand([string]$manufacturer) {
        foreach ($brand in $this.BrandPatterns.Keys) {
            foreach ($pattern in $this.BrandPatterns[$brand]) {
                if ($manufacturer -like "*$pattern*") {
                    return $brand
                }
            }
        }
        return "Unknown"
    }

    [string] DetectCategory([string]$updateName) {
        foreach ($category in $this.CategoryPatterns.Keys) {
            foreach ($pattern in $this.CategoryPatterns[$category]) {
                if ($updateName -like "*$pattern*") {
                    return $category
                }
            }
        }
        return "Other"
    }

    # Maps a DCU report category string to a standard category name
    [string] MapReportCategory([string]$reportCategory) {
        foreach ($stdCategory in $this.CategoryMappings.Keys) {
            if ($this.CategoryMappings[$stdCategory] -contains $reportCategory) {
                return $stdCategory
            }
        }
        return "Other"
    }

    # Maps Windows DeviceClass to standard category
    [string] MapDeviceClass([string]$deviceClass) {
        if ($this.DeviceClassMappings.ContainsKey($deviceClass)) {
            return $this.DeviceClassMappings[$deviceClass]
        }
        return "Other"
    }

    # Detects brand from update name using category-specific brand patterns (legacy approach)
    [string] DetectCategoryBrand([string]$updateName, [string]$category) {
        if (-not $this.CategoryBrands.ContainsKey($category)) {
            return $null
        }
        
        foreach ($brand in $this.CategoryBrands[$category]) {
            if ($updateName -match [regex]::Escape($brand)) {
                return $brand
            }
        }
        return $null
    }

    # Legacy-compatible driver matching by category and brand (from main branch)
    # This is the preferred method when working with Dell Command Update scan results
    [object] FindBestDriverMatchByCategory([string]$updateName, [array]$systemDrivers, [string]$category) {
        if ($null -eq $systemDrivers -or $systemDrivers.Count -eq 0) {
            return $null
        }
        
        # Find update brand using category-specific brand patterns
        $updateBrand = $this.DetectCategoryBrand($updateName, $category)
        
        if (-not $updateBrand) { return $null }
        
        # Pre-filter drivers by same brand
        $matchingDrivers = $systemDrivers | Where-Object {
            $_.DeviceName -match [regex]::Escape($updateBrand)
        }
        
        if (-not $matchingDrivers -or $matchingDrivers.Count -eq 0) { return $null }
        
        # Score only the pre-filtered drivers
        $bestMatch = $null
        $highestScore = 0
        
        foreach ($driver in $matchingDrivers) {
            $score = 10  # Base score for brand match
            
            # Bluetooth-specific scoring (important for Network category)
            $isUpdateBluetooth = $updateName -match "Bluetooth"
            $isDriverBluetooth = $driver.DeviceName -match "Bluetooth"
            
            if ($isUpdateBluetooth -and $isDriverBluetooth) {
                $score += 20
            }
            elseif ($isUpdateBluetooth -xor $isDriverBluetooth) {
                $score -= 5
            }
            
            # Additional keyword matching
            $updateWords = $updateName.ToLower() -split '\s+|[-_]'
            $driverWords = $driver.DeviceName.ToLower() -split '\s+|[-_]'
            $commonWords = $updateWords | Where-Object { $driverWords -contains $_ -and $_.Length -gt 2 }
            $score += ($commonWords.Count * 3)
            
            if ($score -gt $highestScore) {
                $highestScore = $score
                $bestMatch = @{
                    Driver = $driver
                    Score = $score
                    Category = $category
                    Brand = $updateBrand
                    DriverVersion = $driver.DriverVersion
                    DeviceName = $driver.DeviceName
                }
            }
        }
        
        return $bestMatch
    }

    # Generic driver matching (for non-categorized searches)
    [object] FindBestDriverMatch([string]$updateName, [array]$installedDrivers) {
        if ($null -eq $installedDrivers -or $installedDrivers.Count -eq 0) {
            return $null
        }
        
        $updateCategory = $this.DetectCategory($updateName)
        $updateNameLower = $updateName.ToLower()
        
        $bestMatch = $null
        $bestScore = 0
        
        foreach ($driver in $installedDrivers) {
            $score = 0
            $driverName = $driver.DriverName
            $driverProvider = $driver.ProviderName
            
            if ([string]::IsNullOrEmpty($driverName)) { continue }
            
            $driverNameLower = $driverName.ToLower()
            
            # Category match (highest weight)
            $driverCategory = $this.DetectCategory($driverName)
            if ($driverCategory -eq $updateCategory -and $updateCategory -ne "Other") {
                $score += 50
            }
            
            # Provider/Brand match
            $updateBrand = $this.DetectBrandFromName($updateName)
            $driverBrand = $this.DetectBrand($driverProvider)
            if ($updateBrand -eq $driverBrand -and $updateBrand -ne "Unknown") {
                $score += 30
            }
            
            # Partial name match (keywords)
            $updateWords = $updateNameLower -split '\s+|[-_]'
            $driverWords = $driverNameLower -split '\s+|[-_]'
            $commonWords = $updateWords | Where-Object { $driverWords -contains $_ -and $_.Length -gt 2 }
            $score += ($commonWords.Count * 5)
            
            # Version pattern detection
            if ($updateNameLower -match '\d+\.\d+' -and $driverNameLower -match '\d+\.\d+') {
                $score += 10
            }
            
            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestMatch = @{
                    Driver = $driver
                    Score = $score
                    Category = $driverCategory
                    Brand = $driverBrand
                }
            }
        }
        
        # Only return match if score is above threshold
        if ($bestScore -ge 20) {
            return $bestMatch
        }
        
        return $null
    }

    [string] DetectBrandFromName([string]$name) {
        foreach ($brand in $this.BrandPatterns.Keys) {
            foreach ($pattern in $this.BrandPatterns[$brand]) {
                if ($name -like "*$pattern*") {
                    return $brand
                }
            }
        }
        return "Unknown"
    }

    [hashtable] CompareVersions([string]$installedVersion, [string]$updateVersion) {
        $result = @{
            Installed = $installedVersion
            Update = $updateVersion
            IsNewer = $false
            ParseError = $false
        }
        
        try {
            # Extract version numbers
            $installedNums = [regex]::Matches($installedVersion, '\d+')
            $updateNums = [regex]::Matches($updateVersion, '\d+')
            
            $maxSegments = [Math]::Max($installedNums.Count, $updateNums.Count)
            
            for ($i = 0; $i -lt $maxSegments; $i++) {
                $instVal = if ($i -lt $installedNums.Count) { [int]$installedNums[$i].Value } else { 0 }
                $updVal = if ($i -lt $updateNums.Count) { [int]$updateNums[$i].Value } else { 0 }
                
                if ($updVal -gt $instVal) {
                    $result.IsNewer = $true
                    break
                }
                elseif ($updVal -lt $instVal) {
                    break
                }
            }
        }
        catch {
            $result.ParseError = $true
        }
        
        return $result
    }

    [string] FormatMatchResult([object]$match, [string]$updateName, [string]$updateVersion) {
        if ($null -eq $match) {
            return "No matching installed driver found for: $updateName"
        }
        
        $driver = $match.Driver
        $comparison = $this.CompareVersions($driver.DriverVersion, $updateVersion)
        
        $newerText = if ($comparison.IsNewer) { "[NEWER]" } else { "[SAME/OLDER]" }
        
        return @"
Update: $updateName ($updateVersion)
Matched Driver: $($driver.DriverName)
Category: $($match.Category) | Brand: $($match.Brand)
Installed Version: $($driver.DriverVersion) -> Update: $updateVersion $newerText
Match Score: $($match.Score)
"@
    }

    # Filter drivers by version compatibility with updates (from legacy main branch)
    # Returns drivers that have matching updates and valid version info
    [array] FilterDriversByVersion([array]$drivers, [array]$updates, [string]$category) {
        if ($null -eq $drivers -or $drivers.Count -eq 0) { return @() }
        if ($null -eq $updates -or $updates.Count -eq 0) { return @() }
        
        # Pre-filter updates by category first
        $categoryUpdates = $updates | Where-Object {
            $updateCategory = if ($_.category) { $_.category } else { "Unknown Category" }
            $mappedCategories = $this.CategoryMappings[$category]
            if ($mappedCategories) {
                $updateCategory -in $mappedCategories
            } else {
                $false
            }
        }
        
        if (-not $categoryUpdates -or $categoryUpdates.Count -eq 0) { return @() }
        
        # Create lookup hash for faster brand matching
        $updateBrandMap = @{}
        foreach ($update in $categoryUpdates) {
            $updateName = if ($update.name) { $update.name } else { "Unknown Name" }
            $updateVersion = if ($update.version) { $update.version } else { "Unknown Version" }
            
            if ($this.CategoryBrands.ContainsKey($category)) {
                foreach ($brand in $this.CategoryBrands[$category]) {
                    if ($updateName -match $brand) {
                        if (-not $updateBrandMap[$brand]) { $updateBrandMap[$brand] = @() }
                        $updateBrandMap[$brand] += @{
                            Name    = $updateName
                            Version = $updateVersion
                            Update  = $update
                        }
                        break
                    }
                }
            }
        }
        
        # Now filter drivers efficiently
        $filteredDrivers = @()
        foreach ($driver in $drivers) {
            # Skip drivers with unknown version
            if ($driver.DriverVersion -eq "Unknown") { continue }
            
            $hasValidUpdate = $false
            
            if ($this.CategoryBrands.ContainsKey($category)) {
                foreach ($brand in $this.CategoryBrands[$category]) {
                    if ($driver.DeviceName -match $brand -and $updateBrandMap[$brand]) {
                        foreach ($updateInfo in $updateBrandMap[$brand]) {
                            if ($updateInfo.Version -ne "Unknown Version") {
                                try {
                                    $currentVersionObj = [System.Version]$driver.DriverVersion
                                    $xmlVersionObj = [System.Version]$updateInfo.Version
                                    
                                    if ($xmlVersionObj -ge $currentVersionObj) {
                                        $hasValidUpdate = $true
                                        break
                                    }
                                }
                                catch {
                                    # Version parse failed - include driver anyway
                                    $hasValidUpdate = $true
                                    break
                                }
                            }
                        }
                        if ($hasValidUpdate) { break }
                    }
                }
            }
            
            if ($hasValidUpdate) {
                $filteredDrivers += $driver
            }
        }
        
        return $filteredDrivers
    }

    # Filter applications by version compatibility with updates
    [array] FilterApplicationsByVersion([array]$applications, [array]$updates) {
        if ($null -eq $applications -or $applications.Count -eq 0) { return @() }
        if ($null -eq $updates -or $updates.Count -eq 0) { return @() }
        
        # Pre-filter updates by Application category
        $appUpdates = $updates | Where-Object {
            $updateCategory = if ($_.category) { $_.category } else { "Unknown Category" }
            $updateCategory -eq "Application"
        }
        
        if (-not $appUpdates -or $appUpdates.Count -eq 0) { return @() }
        
        # Build update lookup by normalized name
        $updateNameMap = @{}
        foreach ($update in $appUpdates) {
            $updateName = if ($update.name) { $update.name } else { "Unknown Name" }
            $normalizedName = $this.NormalizeAppName($updateName)
            $updateNameMap[$normalizedName] = @{
                Name    = $updateName
                Version = if ($update.version) { $update.version } else { "Unknown Version" }
                Update  = $update
            }
        }
        
        # Filter applications
        $filteredApps = @()
        foreach ($app in $applications) {
            if ($app.Version -eq "Unknown") { continue }
            
            $normalizedAppName = $this.NormalizeAppName($app.Name)
            if ($updateNameMap.ContainsKey($normalizedAppName)) {
                $filteredApps += $app
            }
        }
        
        return $filteredApps
    }

    # Normalize application names for matching (strip trailing 'Application', remove spaces, lowercase)
    [string] NormalizeAppName([string]$name) {
        if ([string]::IsNullOrEmpty($name)) { return "" }
        $n = $name -replace '(?i)\s*Application$', ''
        $n = $n -replace '\s+', ''
        return $n.ToLowerInvariant()
    }

    # Get the list of supported DCU categories
    [array] GetSupportedCategories() {
        return @("Audio", "Video", "Network", "Storage", "Input", "Chipset", "BIOS", "Application", "Others")
    }

    # Check if a category is supported for brand-based matching
    [bool] SupportsCategoryBrandMatching([string]$category) {
        return $this.CategoryBrands.ContainsKey($category)
    }
}
