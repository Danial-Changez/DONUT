# DiskUsage
#
# Pure DTO + parsing/formatting for the "Find big folders on C:" feature: the
# largest folders on a remote machine's C: drive, gathered by a WizTree MFT scan
# (exported to CSV, copied back, parsed here). WPF-free so the parse/format logic
# is unit-tested; the presenter renders it. Mirrors the MachineInventory /
# InventoryFormat pure-helper pattern, including the ToHashtable/FromHashtable
# round-trip used to cache the result on the recents store.

# One folder and its on-disk size.
class FolderUsage {
    [string] $Path = ''
    [long]   $SizeBytes = 0

    static [FolderUsage] FromHashtable([hashtable]$h) {
        $f = [FolderUsage]::new()
        if ($null -eq $h) { return $f }
        $f.Path = [string]$h['path']
        $f.SizeBytes = [FolderUsage]::AsLong($h['sizeBytes'])
        return $f
    }

    [hashtable] ToHashtable() {
        return @{
            path      = $this.Path
            sizeBytes = $this.SizeBytes
        }
    }

    hidden static [long] AsLong([object]$v) {
        if ($null -eq $v) { return 0 }
        $out = [long]0
        if ([long]::TryParse([string]$v, [ref]$out)) { return $out }
        return 0
    }
}

# The result of a disk-usage scan: when it ran + the ranked top folders.
class DiskUsageReport {
    [string]        $ScannedAt = ''     # ISO8601 UTC when the scan was parsed
    [FolderUsage[]] $Folders = @()

    static [DiskUsageReport] FromHashtable([hashtable]$h) {
        $r = [DiskUsageReport]::new()
        if ($null -eq $h) { return $r }
        $r.ScannedAt = [string]$h['scannedAt']
        $list = [System.Collections.Generic.List[FolderUsage]]::new()
        foreach ($item in @($h['folders'])) {
            if ($null -eq $item) { continue }
            $list.Add([FolderUsage]::FromHashtable([hashtable]$item))
        }
        $r.Folders = $list.ToArray()
        return $r
    }

    # Flattens to a plain hashtable (folders as an array of hashtables) so it can
    # be cached in the recents store and round-trip through ConvertTo/FromJson.
    [hashtable] ToHashtable() {
        $arr = @()
        foreach ($f in $this.Folders) { $arr += $f.ToHashtable() }
        return @{
            scannedAt = $this.ScannedAt
            folders   = $arr
        }
    }
}

# Pure parser for WizTree's CSV export. Static, WPF-free, tested.
class WizTreeCsv {
    # Parses a WizTree folder export into a ranked DiskUsageReport.
    #
    # WizTree's CSV may lead with a banner/generator line before the real header
    # row (which starts with "File Name"); folder paths are full and end with a
    # trailing backslash, and the volume root itself ("C:\") is listed first as
    # the whole-drive total. We locate the header, parse from there (ConvertFrom-Csv
    # handles quoted paths containing commas), drop the volume root, rank by size
    # descending, and cap at topN. Never throws: empty/garbage input -> empty report.
    static [DiskUsageReport] ParseTopFolders([string]$csvText, [int]$topN) {
        $report = [DiskUsageReport]::new()
        $report.ScannedAt = [datetime]::UtcNow.ToString('o')
        $report.Folders = @()

        if ([string]::IsNullOrWhiteSpace($csvText)) { return $report }

        # Split into lines and find the header row (first line mentioning "File Name").
        $lines = $csvText -split "`r?`n"
        $headerIndex = -1
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match '(?i)(^|,)\s*"?File Name"?\s*,') { $headerIndex = $i; break }
        }
        if ($headerIndex -lt 0) { return $report }

        $body = $lines[$headerIndex..($lines.Length - 1)] -join "`n"

        $rows = $null
        try { $rows = $body | ConvertFrom-Csv } catch { return $report }
        if ($null -eq $rows) { return $report }

        $list = [System.Collections.Generic.List[FolderUsage]]::new()
        foreach ($row in $rows) {
            $path = [string]$row.'File Name'
            if ([string]::IsNullOrWhiteSpace($path)) { continue }
            $path = $path.Trim()
            # Skip the volume root (e.g. "C:\" / "C:") — that's the whole-drive total.
            if ($path -match '^[A-Za-z]:\\?$') { continue }

            $f = [FolderUsage]::new()
            $f.Path = $path
            $f.SizeBytes = [FolderUsage]::AsLong($row.Size)
            $list.Add($f)
        }

        $ranked = $list | Sort-Object -Property SizeBytes -Descending
        if ($topN -gt 0) { $ranked = $ranked | Select-Object -First $topN }
        $report.Folders = @($ranked)
        return $report
    }
}

# Pure formatting for the big-folders list rows. Static, WPF-free, tested.
class DiskUsageFormat {
    # Human-readable size: GB at >= 1 GB, otherwise MB (1 decimal, InvariantCulture).
    # Reuses the 1024^3 GB convention from InventoryFormat.DiskFreeLabel.
    static [string] SizeLabel([long]$bytes) {
        $ci = [System.Globalization.CultureInfo]::InvariantCulture
        $gb = 1073741824.0   # 1024^3
        $mb = 1048576.0      # 1024^2
        if ($bytes -ge $gb) {
            $v = [Math]::Round($bytes / $gb, 1)
            return "$($v.ToString($ci)) GB"
        }
        $v = [Math]::Round($bytes / $mb, 1)
        return "$($v.ToString($ci)) MB"
    }
}
