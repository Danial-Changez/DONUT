using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Matches Dell Command Update results to installed drivers by brand/category.

.DESCRIPTION
    Pattern tables (brand, category) plus version comparison, used to enrich the
    update report with "what is this, and is it newer than what's installed?"
    detail.
#>
class DriverMatchingService {
    [hashtable] $BrandPatterns
    [hashtable] $CategoryPatterns
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
        # Dell only: the fleet is Dell and DCU reports never name another machine brand.
        $this.BrandPatterns = @{
            "Dell" = @("Dell Inc.", "Dell", "DELL")
        }

        $this.CategoryPatterns = @{
            "BIOS"        = @("BIOS", "System BIOS", "UEFI", "Firmware")
            "Chipset"     = @("Chipset", "Intel Management Engine", "ME", "AMT")
            "Audio"       = @("Audio", "Sound", "Realtek Audio", "High Definition Audio", "MEDIA")
            "Network"     = @("Network", "Ethernet", "WiFi", "Wireless", "LAN", "WLAN",
                "Intel Dual Band", "NET", "Docks/Stands")
            "Graphics"    = @("Graphics", "Display", "Video", "VGA", "Intel HD", "Intel UHD",
                "GeForce", "Radeon", "DISPLAY")
            "Storage"     = @("Storage", "RAID", "AHCI", "NVMe", "SSD", "Intel RST")
            "USB"         = @("USB", "USB Controller", "USB 3.0", "USB-C")
            "Bluetooth"   = @("Bluetooth", "BT")
            "Camera"      = @("Camera", "Webcam", "IR Camera", "Integrated Camera")
            "Touchpad"    = @("Touchpad", "Trackpad", "Mouse", "Pointing Device", "Input")
            "Thunderbolt" = @("Thunderbolt", "TB3", "TB4")
            "Application" = @("Application", "App")
            "Others"      = @("Others", "Other")
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

    # Scores every installed driver and returns the best above the confidence floor.
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

            $driverCategory = $this.DetectCategory($driverName)
            if ($driverCategory -eq $updateCategory -and $updateCategory -ne "Other") {
                $score += 50
            }

            $updateBrand = $this.DetectBrand($updateName)
            $driverBrand = $this.DetectBrand($driverProvider)
            if ($updateBrand -eq $driverBrand -and $updateBrand -ne "Unknown") {
                $score += 30
            }

            # Words of two letters or less match too many drivers to be evidence.
            $updateWords = $updateNameLower -split '\s+|[-_]'
            $driverWords = $driverNameLower -split '\s+|[-_]'
            $commonWords = $updateWords |
                Where-Object { $driverWords -contains $_ -and $_.Length -gt 2 }
            $score += ($commonWords.Count * 5)

            if ($updateNameLower -match '\d+\.\d+' -and $driverNameLower -match '\d+\.\d+') {
                $score += 10
            }

            if ($score -gt $bestScore) {
                $bestScore = $score
                $bestMatch = @{
                    Driver   = $driver
                    Score    = $score
                    Category = $driverCategory
                    Brand    = $driverBrand
                }
            }
        }

        if ($bestScore -ge 20) {
            return $bestMatch
        }

        return $null
    }

    [hashtable] CompareVersions([string]$installedVersion, [string]$updateVersion) {
        $result = @{
            Installed  = $installedVersion
            Update     = $updateVersion
            IsNewer    = $false
            ParseError = $false
        }

        try {
            $installedNums = [regex]::Matches($installedVersion, '\d+')
            $updateNums = [regex]::Matches($updateVersion, '\d+')

            $maxSegments = [Math]::Max($installedNums.Count, $updateNums.Count)

            for ($i = 0; $i -lt $maxSegments; $i++) {
                $instVal = if ($i -lt $installedNums.Count) { [int]$installedNums[$i].Value }
                else { 0 }
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
}
