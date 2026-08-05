<#
.SYNOPSIS
    Converts a Lucide SVG icon into the single-Geometry line Icons.xaml uses.

.DESCRIPTION
    Lucide (https://lucide.dev) is the app's icon source - the same library the
    Arcane/shadcn look derives from. Its icons are 24x24 stroke outlines built
    from several SVG elements (path/circle/line/rect/polyline). WPF wants one
    Geometry string, so this flattens every element into path syntax and prints
    a ready-to-paste <Geometry x:Key="..."> line.

    Icons render as STROKES (see the lucideIcon style in Icons.xaml), never
    fills - a filled outline skeleton is how an icon ends up looking broken.

.PARAMETER Path
    The downloaded .svg file, e.g. from https://unpkg.com/lucide-static/icons/x.svg

.PARAMETER Key
    The x:Key for the emitted line. Defaults to the file's base name.

.EXAMPLE
    pwsh -File tools\Convert-LucideIcon.ps1 -Path circle-help.svg -Key Help
#>
param(
    [Parameter(Mandatory = $true)][string] $Path,
    [string] $Key
)

$ErrorActionPreference = 'Stop'

if (-not $Key) { $Key = [IO.Path]::GetFileNameWithoutExtension($Path) }
[xml]$svg = Get-Content -LiteralPath $Path -Raw

# A leading relative moveto is legal standalone but wrong once paths concatenate into one
# Geometry: it becomes relative to the previous subpath's endpoint, so rewrite it absolute.
function ConvertTo-AbsoluteStart([string]$d) {
    $d = $d.Trim()
    if ($d -cnotmatch '^m') { return $d }
    if ($d -match '^m\s*((?:[-+]?[\d.]+[,\s]*)+)(.*)$') {
        $nums = @([regex]::Matches($Matches[1], '[-+]?[\d.]+') | ForEach-Object { $_.Value })
        $out = 'M{0},{1}' -f $nums[0], $nums[1]
        if ($nums.Count -gt 2) { $out += ' l' + (($nums | Select-Object -Skip 2) -join ',') }
        return $out + ' ' + $Matches[2]
    }
    return $d
}

$parts = foreach ($el in $svg.svg.ChildNodes) {
    switch ($el.LocalName) {
        'path' { ConvertTo-AbsoluteStart $el.d }
        'circle' {
            # Two half-circle arcs starting at the left edge.
            $cx = [double]$el.cx; $cy = [double]$el.cy; $r = [double]$el.r
            'M{0},{1} a{2},{2} 0 1 0 {3},0 a{2},{2} 0 1 0 -{3},0' -f ($cx - $r), $cy, $r, (2 * $r)
        }
        'line' { 'M{0},{1} L{2},{3}' -f $el.x1, $el.y1, $el.x2, $el.y2 }
        'rect' {
            $x = [double]$el.x; $y = [double]$el.y
            $w = [double]$el.width; $h = [double]$el.height
            $rx = if ($el.rx) { [double]$el.rx } else { 0 }
            if ($rx -eq 0) {
                'M{0},{1} h{2} v{3} h-{2} z' -f $x, $y, $w, $h
            }
            else {
                ('M{0},{1} h{2} a{3},{3} 0 0 1 {3},{3} v{4} a{3},{3} 0 0 1 -{3},{3} ' +
                'h-{2} a{3},{3} 0 0 1 -{3},-{3} v-{4} a{3},{3} 0 0 1 {3},-{3} z') -f
                ($x + $rx), $y, ($w - 2 * $rx), $rx, ($h - 2 * $rx)
            }
        }
        'polyline' {
            $pts = ($el.points -split '[\s,]+') | Where-Object { $_ }
            $cmds = for ($i = 0; $i -lt $pts.Count; $i += 2) {
                '{0}{1},{2}' -f $(if ($i -eq 0) { 'M' } else { 'L' }), $pts[$i], $pts[$i + 1]
            }
            $cmds -join ' '
        }
        'polygon' {
            $pts = ($el.points -split '[\s,]+') | Where-Object { $_ }
            $cmds = for ($i = 0; $i -lt $pts.Count; $i += 2) {
                '{0}{1},{2}' -f $(if ($i -eq 0) { 'M' } else { 'L' }), $pts[$i], $pts[$i + 1]
            }
            ($cmds -join ' ') + ' z'
        }
        default { }
    }
}

'    <Geometry x:Key="{0}">{1}</Geometry>' -f $Key, (($parts | Where-Object { $_ }) -join ' ')
