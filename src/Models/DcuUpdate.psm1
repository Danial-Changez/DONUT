<#
.SYNOPSIS
    One available Dell Command Update, parsed from a <host>-Updates.xml <update> node.

.DESCRIPTION
    The DCU report stores each update as CHILD elements (name/version/urgency/type/category/
    date/bytes), not attributes - so the fields must be read explicitly ($node.InnerText would
    mash them all together). This is the typed, display-ready row the detail-pane list binds to:
    the found version, the installed version + IsNewer from a driver match (blank/"(latest)" for
    BIOS and unmatched items), urgency for the severity badge, and a human-readable size. All
    display strings are precomputed (WPF binds properties, not methods).

.NOTES
    WPF-free so the parse + formatting are unit-tested headless (mirrors SearchRowViewModel).
    Built via the static New(...) factory so the version/size formatting lives in one place.
#>
class DcuUpdate {
    [string] $Name = ''
    [string] $Category = ''
    [string] $Urgency = ''       # Urgent | Recommended | Optional (drives the severity badge)
    [string] $VersionText = ''   # "1.2.0 -> 1.4.1" (matched) or "1.36.0" (no installed baseline)
    [string] $SizeText = ''      # "26.7 MB" / "1.3 GB" (blank when size unknown)
    [bool]   $IsNewer = $false

    static [DcuUpdate] Create(
        [string]$name, [string]$newVersion, [string]$currentVersion, [bool]$hasMatch,
        [bool]$isNewer, [string]$urgency, [string]$category, [long]$sizeBytes
    ) {
        $u = [DcuUpdate]::new()
        $u.Name = $name
        $u.Category = $category
        $u.Urgency = $urgency
        $u.IsNewer = $isNewer
        if ($hasMatch -and -not [string]::IsNullOrWhiteSpace($currentVersion)) {
            $u.VersionText = "$currentVersion  →  $newVersion"
        }
        else {
            # Nothing to diff against, and "(latest)" was redundant since every update is latest.
            $u.VersionText = "$newVersion"
        }
        $u.SizeText = [DcuUpdate]::FormatSize($sizeBytes)
        return $u
    }

    # GB at >= 1 GB else MB (1 decimal, InvariantCulture), mirroring DiskUsageFormat.SizeLabel.
    hidden static [string] FormatSize([long]$bytes) {
        if ($bytes -le 0) { return '' }
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        $gb = 1073741824.0
        $mb = 1048576.0
        if ($bytes -ge $gb) { return "$(([Math]::Round($bytes / $gb, 1)).ToString($ci)) GB" }
        return "$(([Math]::Round($bytes / $mb, 1)).ToString($ci)) MB"
    }

    # Severity order for the updates list: Urgent first, then Recommended, Optional, unknown.
    static [int] UrgencyRank([string]$urgency) {
        switch ("$urgency".Trim().ToLowerInvariant()) {
            'urgent' { return 0 }
            'recommended' { return 1 }
            'optional' { return 2 }
            default { return 3 }
        }
        return 3
    }
}
