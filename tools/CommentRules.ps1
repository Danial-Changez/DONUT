<#
.SYNOPSIS
    The comment-cap scanner shared by tools/Invoke-Lint.ps1 and the per-edit
    style hook.

.DESCRIPTION
    Implements the comment-length rule in docs/development/coding-style.md: one
    line, two only above a file header, a class, or a method or function
    definition, with dashed lists, comment-based help, C# /// doc comments and
    here-string bodies exempt.

    Dot-source this file, then call Get-CommentFinding with any mix of
    PowerShell, C#, web and XAML files. The rule lives here once so the repo-wide
    lint sweep and the hook can never drift apart.
#>

function Get-LongComment {
    param(
        [System.IO.FileInfo[]] $Files,
        [string] $Marker,      # comment prefix regex, e.g. '//(?!/)' or '#'
        [string] $ExemptNext,  # a two-line block is allowed above a line matching this
        [switch] $PowerShell   # skip <# #> help blocks and here-strings
    )
    foreach ($file in $Files) {
        $lines = @(Get-Content $file.FullName)
        $run = 0; $inHelp = $false; $inHere = $false
        for ($i = 0; $i -le $lines.Count; $i++) {
            $line = if ($i -lt $lines.Count) { $lines[$i] } else { '' }
            if ($PowerShell) {
                # Help blocks carry the long rationale by design, and a here-string
                # is shipped payload rather than commentary.
                if ($inHere) {
                    if ($line -match "^\s*('@|""@)") { $inHere = $false }
                    $run = 0; continue
                }
                if ($inHelp) {
                    if ($line -match '#>') { $inHelp = $false }
                    $run = 0; continue
                }
                if ($line -match "@'|@""") { $inHere = $true; $run = 0; continue }
                if ($line -match '^\s*<#') {
                    if ($line -notmatch '#>') { $inHelp = $true }
                    $run = 0; continue
                }
            }
            $isComment = $line -match "^\s*$Marker" -and
            $line -notmatch '^\s*#(requires|region|endregion)' -and
            $line -notmatch '^\s*(#|//)\s*-{3,}'
            if ($i -lt $lines.Count -and $isComment) { $run++; continue }
            if ($run -ge 2) {
                $next = $line
                $exempt = ($i - $run) -eq 0 -or $next -match $ExemptNext
                # A dashed list may run long when it replaces denser prose.
                $bullets = @($lines[($i - $run)..($i - 1)] -match "^\s*$Marker\s+-\s").Count
                $limit = if ($bullets -ge 2) { $run } elseif ($exempt) { 2 } else { 1 }
                if ($run -gt $limit) {
                    [pscustomobject]@{
                        File  = $file.Name
                        Line  = $i - $run + 1
                        Lines = $run
                        Max   = $limit
                    }
                }
            }
            $run = 0
        }
    }
}

# XAML has no per-line marker, so a block is measured from <!-- to its -->.
function Get-LongXamlComment {
    param([System.IO.FileInfo[]] $Files)
    foreach ($file in $Files) {
        $lines = @(Get-Content $file.FullName)
        $open = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($open -lt 0 -and $lines[$i] -match '<!--') { $open = $i }
            if ($open -lt 0 -or $lines[$i] -notmatch '-->') { continue }
            $len = $i - $open + 1
            if ($len -ge 2) {
                $next = if ($i + 1 -lt $lines.Count) { $lines[$i + 1] } else { '' }
                # A header opens the file, and a section comment precedes an element.
                $exempt = $open -eq 0 -or $next -match '^\s*<[A-Za-z]'
                $bullets = @($lines[$open..$i] -match '^\s*-\s').Count
                $limit = if ($bullets -ge 2) { $len } elseif ($exempt) { 2 } else { 1 }
                if ($len -gt $limit) {
                    [pscustomobject]@{
                        File  = $file.Name
                        Line  = $open + 1
                        Lines = $len
                        Max   = $limit
                    }
                }
            }
            $open = -1
        }
    }
}

$script:SlashExempt = '^\s*(namespace|#nullable|export|import|const|function|class)|' +
'^\s*((public|internal|sealed|static|abstract|partial)\s+)*(class|record|struct|interface|enum)\s'
# A PowerShell method is a return type then a name, and a constructor is bare. The
# type class allows nested brackets so an array return like [string[]] still matches.
$script:PsExempt = '^\s*(class|enum|function)\s|' +
'^\s*(hidden\s+)?(static\s+)?(\[[\w\.\[\]]+\]\s*)?[\w-]+\s*\('

# Classifies by extension and applies the matching marker and exemption set.
function Get-CommentFinding {
    param([System.IO.FileInfo[]] $Files)
    $ps = @($Files | Where-Object { $_.Extension -in @('.ps1', '.psm1') })
    $xaml = @($Files | Where-Object Extension -EQ '.xaml')
    $slash = @($Files | Where-Object { $ps -notcontains $_ -and $xaml -notcontains $_ })
    return @(
        Get-LongComment -Files $slash `
                        -Marker '//(?!/)' `
                        -ExemptNext $script:SlashExempt
        Get-LongComment -Files $ps `
                        -Marker '#' `
                        -ExemptNext $script:PsExempt `
                        -PowerShell
        Get-LongXamlComment -Files $xaml
    )
}
