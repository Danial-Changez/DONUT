using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Matches Dell Command Update results to installed drivers by type and category.

.DESCRIPTION
    Pairs each DCU update with the installed driver it would replace, so a card
    can show the installed version beside the new one. Only driver-type updates
    are fuzzy-matched, since applications and firmware have no PnP baseline to
    diff against, and a BIOS update pairs exactly with the scan's own Win32_BIOS
    row. A wrong pairing misleads worse than a blank, so a match requires the
    categories to agree and the names to share at least one real word.
#>
class DriverMatchingService {
    [hashtable] $BrandPatterns
    [System.Collections.Specialized.OrderedDictionary] $CategoryPatterns
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

        # Ordered because the first hit wins, with the scanned device classes up front.
        $this.CategoryPatterns = [ordered]@{
            "BIOS"        = @("BIOS", "System BIOS", "UEFI", "Firmware")
            "Chipset"     = @("Chipset", "Intel Management Engine", "ME", "AMT")
            "Bluetooth"   = @("Bluetooth", "BT")
            "Audio"       = @("Audio", "Sound", "Realtek Audio", "High Definition Audio", "MEDIA")
            "Network"     = @("Network", "Ethernet", "WiFi", "Wireless", "LAN", "WLAN",
                "Intel Dual Band", "NET", "Docks/Stands")
            "Graphics"    = @("Graphics", "Display", "Video", "VGA", "Intel HD", "Intel UHD",
                "GeForce", "Radeon", "DISPLAY")
            "Thunderbolt" = @("Thunderbolt", "TB3", "TB4")
            "Storage"     = @("Storage", "RAID", "AHCI", "NVMe", "SSD", "Intel RST")
            "USB"         = @("USB", "USB Controller", "USB 3.0", "USB-C")
            "Camera"      = @("Camera", "Webcam", "IR Camera", "Integrated Camera")
            "Touchpad"    = @("Touchpad", "Trackpad", "Mouse", "Pointing Device", "Input")
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

    # Word-bounded, so a short pattern like ME can never hit inside Enumerator.
    [string] DetectCategory([string]$updateName) {
        foreach ($category in $this.CategoryPatterns.Keys) {
            foreach ($pattern in $this.CategoryPatterns[$category]) {
                if ($updateName -match "\b$([regex]::Escape($pattern))\b") {
                    return $category
                }
            }
        }
        return "Other"
    }

    # Pairs one update with the installed driver it would replace, or null when unsure.
    # Unsure always beats a best guess, since a wrong baseline misreads as an upgrade.
    [object] FindBestDriverMatch([string]$updateName, [string]$updateType,
        [string]$updateCategory, [array]$installedDrivers) {
        if ($null -eq $installedDrivers -or $installedDrivers.Count -eq 0) {
            return $null
        }

        $type = "$updateType".Trim().ToLowerInvariant()
        $category = $this.ResolveUpdateCategory($updateName, $updateCategory)

        if ($type -eq 'bios' -or $category -eq 'BIOS') {
            return $this.MatchBiosRow($installedDrivers)
        }
        # Applications, firmware and utilities have no PnP driver row to diff against.
        if ($type -and $type -ne 'driver') { return $null }
        if ($category -eq 'Other') { return $null }

        $updateWords = $this.NameWords($updateName)
        $bestMatch = $null
        $bestScore = 0
        foreach ($driver in $installedDrivers) {
            if ([string]::IsNullOrEmpty($driver.DriverName)) { continue }
            if ($this.GetDriverCategory($driver) -ne $category) { continue }
            # A shared category alone is not evidence: the names must share a word too.
            $common = @($this.NameWords([string]$driver.DriverName) |
                    Where-Object { $updateWords -contains $_ })
            if ($common.Count -gt $bestScore) {
                $bestScore = $common.Count
                $bestMatch = @{
                    Driver   = $driver
                    Score    = $bestScore
                    Category = $category
                    Brand    = $this.DetectBrand([string]$driver.ProviderName)
                }
            }
        }
        return $bestMatch
    }

    # BIOS pairs with the scan's own Win32_BIOS row, never a fuzzy PnP guess.
    hidden [object] MatchBiosRow([array]$installedDrivers) {
        foreach ($driver in $installedDrivers) {
            if ([string]$driver.DriverName -eq 'Dell System BIOS') {
                return @{
                    Driver   = $driver
                    Score    = 100
                    Category = 'BIOS'
                    Brand    = $this.DetectBrand([string]$driver.ProviderName)
                }
            }
        }
        return $null
    }

    # DCU's own category element outranks name sniffing when it maps to a known bucket.
    hidden [string] ResolveUpdateCategory([string]$updateName, [string]$updateCategory) {
        $fromReport = $this.DetectCategory("$updateCategory".Trim())
        if ($fromReport -ne 'Other') { return $fromReport }
        return $this.DetectCategory($updateName)
    }

    # The scan records each row's PnP device class, and old reports fall back to names.
    hidden [string] GetDriverCategory([object]$driver) {
        $map = @{
            'MEDIA' = 'Audio'; 'NET' = 'Network'; 'NETWORK' = 'Network'
            'BLUETOOTH' = 'Bluetooth'; 'DISPLAY' = 'Graphics'; 'BIOS' = 'BIOS'
        }
        $cls = "$($driver.DeviceClass)".Trim().ToUpperInvariant()
        if ($cls -and $map.Contains($cls)) { return [string]$map[$cls] }
        return $this.DetectCategory([string]$driver.DriverName)
    }

    # Words of two letters or less match too many drivers to be evidence.
    hidden [string[]] NameWords([string]$name) {
        return @("$name".ToLowerInvariant() -split '[^a-z0-9]+' |
                Where-Object { $_.Length -gt 2 })
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
                } elseif ($updVal -lt $instVal) {
                    break
                }
            }
        } catch {
            $result.ParseError = $true
            $this.Logger.LogDebug(
                "Version comparison failed for '$installedVersion' vs '$updateVersion': $($_.Exception.Message)")
        }

        return $result
    }
}
