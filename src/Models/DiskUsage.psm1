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

# One node in the rendered folder tree: the original path + size, the display label
# (segment relative to its shown parent), indent depth, and (for the nested view)
# its child folders in size-ranked order.
class FolderTreeNode {
    [string] $Path = ''
    [string] $Label = ''
    [long]   $SizeBytes = 0
    [int]    $Depth = 0
    [FolderTreeNode[]] $Children = @()
}

# Pure helper that arranges a flat, size-ranked folder list into a tree by path
# containment: a folder nests under the deepest other listed folder that is a
# prefix of it. Folders with no listed ancestor are roots. Within each level the
# original (size-descending) order is preserved. Static, WPF-free, tested.
class DiskUsageTree {
    static [FolderTreeNode[]] Build([FolderUsage[]]$folders) {
        $items = @($folders | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.Path) })
        if ($items.Count -eq 0) { return @() }

        # parent[i] = index of the deepest other item whose path is a prefix of items[i].
        $parent = @{}
        for ($i = 0; $i -lt $items.Count; $i++) {
            $best = -1; $bestLen = -1
            for ($j = 0; $j -lt $items.Count; $j++) {
                if ($i -eq $j) { continue }
                $p = $items[$j].Path
                if ($p.Length -lt $items[$i].Path.Length -and
                    $items[$i].Path.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $p.Length -gt $bestLen) {
                    $best = $j; $bestLen = $p.Length
                }
            }
            $parent[$i] = $best
        }

        # Precompute each item's depth (length of its ancestor chain) and display
        # label (segment below its parent), so traversal only carries the index.
        $depth = @{}; $label = @{}
        for ($i = 0; $i -lt $items.Count; $i++) {
            $d = 0; $cur = $parent[$i]
            while ($cur -ge 0) { $d++; $cur = $parent[$cur] }
            $depth[$i] = $d
            $pIdx = $parent[$i]
            $lbl = if ($pIdx -ge 0) { $items[$i].Path.Substring($items[$pIdx].Path.Length) } else { $items[$i].Path }
            if ([string]::IsNullOrEmpty($lbl)) { $lbl = $items[$i].Path }
            $label[$i] = $lbl
        }

        # children[parentIndex] = ordered child indices (-1 key holds the roots).
        $children = @{}
        for ($i = 0; $i -lt $items.Count; $i++) {
            $k = $parent[$i]
            if (-not $children.ContainsKey($k)) { $children[$k] = [System.Collections.Generic.List[int]]::new() }
            $children[$k].Add($i)
        }

        # DFS from the roots, preserving input (size-ranked) order.
        $out = [System.Collections.Generic.List[FolderTreeNode]]::new()
        $stack = [System.Collections.Generic.Stack[int]]::new()
        $roots = if ($children.ContainsKey(-1)) { $children[-1] } else { [System.Collections.Generic.List[int]]::new() }
        for ($r = $roots.Count - 1; $r -ge 0; $r--) { $stack.Push($roots[$r]) }

        while ($stack.Count -gt 0) {
            $idx = $stack.Pop()
            $item = $items[$idx]

            $node = [FolderTreeNode]::new()
            $node.Path = $item.Path
            $node.SizeBytes = $item.SizeBytes
            $node.Depth = $depth[$idx]
            $node.Label = $label[$idx]
            $out.Add($node)

            if ($children.ContainsKey($idx)) {
                $kids = $children[$idx]
                for ($c = $kids.Count - 1; $c -ge 0; $c--) { $stack.Push($kids[$c]) }
            }
        }

        return $out.ToArray()
    }

    # Same containment logic as Build, but returns the ROOT nodes with their Children
    # populated (size-ranked order preserved at every level) for a real TreeView render.
    static [FolderTreeNode[]] BuildNested([FolderUsage[]]$folders) {
        $items = @($folders | Where-Object { $null -ne $_ -and -not [string]::IsNullOrWhiteSpace($_.Path) })
        if ($items.Count -eq 0) { return @() }

        # parent[i] = index of the deepest other item whose path is a prefix of items[i].
        $parent = @{}
        for ($i = 0; $i -lt $items.Count; $i++) {
            $best = -1; $bestLen = -1
            for ($j = 0; $j -lt $items.Count; $j++) {
                if ($i -eq $j) { continue }
                $p = $items[$j].Path
                if ($p.Length -lt $items[$i].Path.Length -and
                    $items[$i].Path.StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase) -and
                    $p.Length -gt $bestLen) {
                    $best = $j; $bestLen = $p.Length
                }
            }
            $parent[$i] = $best
        }

        # One node per item (depth + label below its shown parent).
        $nodes = @()
        for ($i = 0; $i -lt $items.Count; $i++) {
            $d = 0; $cur = $parent[$i]
            while ($cur -ge 0) { $d++; $cur = $parent[$cur] }
            $pIdx = $parent[$i]
            $lbl = if ($pIdx -ge 0) { $items[$i].Path.Substring($items[$pIdx].Path.Length) } else { $items[$i].Path }
            if ([string]::IsNullOrEmpty($lbl)) { $lbl = $items[$i].Path }

            $n = [FolderTreeNode]::new()
            $n.Path = $items[$i].Path
            $n.SizeBytes = $items[$i].SizeBytes
            $n.Depth = $d
            $n.Label = $lbl
            $n.Children = @()
            $nodes += $n
        }

        # Attach each node under its parent (input/size order preserved); collect roots.
        $roots = [System.Collections.Generic.List[FolderTreeNode]]::new()
        for ($i = 0; $i -lt $items.Count; $i++) {
            $pIdx = $parent[$i]
            if ($pIdx -ge 0) { $nodes[$pIdx].Children += $nodes[$i] }
            else { $roots.Add($nodes[$i]) }
        }
        return $roots.ToArray()
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
