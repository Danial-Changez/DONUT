using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Matches Dell Command Update results to installed drivers by brand/category.

.DESCRIPTION
    Pattern tables (brand, category, device-class) plus version comparison and
    result formatting, used to enrich the update report with "what is this, and
    is it newer than what's installed?" detail.
#>
class DriverMatchingService {
    [hashtable] $BrandPatterns
    [hashtable] $CategoryPatterns
    [hashtable] $CategoryMappings
    [hashtable] $DeviceClassMappings
    [LogService] $Logger

    DriverMatchingService() {
        $this.Logger = [NullLogService]::new()
        $this.InitializePatterns()
    }

    DriverMatchingService([LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.InitializePatterns()
    }

    hidden [void] InitializePatterns() {
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
            $this.Logger.LogDebug("Version comparison failed for '$installedVersion' vs '$updateVersion': $($_.Exception.Message)")
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

    # Normalize application names for matching (strip trailing 'Application', remove spaces, lowercase)
    [string] NormalizeAppName([string]$name) {
        if ([string]::IsNullOrEmpty($name)) { return "" }
        $n = $name -replace '(?i)\s*Application$', ''
        $n = $n -replace '\s+', ''
        return $n.ToLowerInvariant()
    }
}
