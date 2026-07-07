#Requires -Version 7
<#
.SYNOPSIS
    PostToolUse hook: flags comment blocks over the two-line cap in edited src files.

.DESCRIPTION
    Reads the Claude Code hook payload (JSON) from stdin and, for edited source files
    under src/ (*.ps1, *.psm1, *.cs), reports any run of 3+ consecutive full-line
    comments - the "one line preferred, two lines maximum" rule in Coding-Style.md that
    neither Invoke-Format nor PSScriptAnalyzer enforces. PowerShell comment-based help
    blocks and C# XML doc comments (///) are exempt (they may span more lines).
    Violations surface via hookSpecificOutput.additionalContext so the comment is
    trimmed - or its rationale moved to .NOTES - immediately, rather than in review.
#>

$ErrorActionPreference = 'Stop'

# --- Read the hook payload from stdin ---
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$filePath = $payload.tool_input.file_path
if (-not $filePath) { $filePath = $payload.tool_response.filePath }
if (-not $filePath) { exit 0 }

# --- Act only on source files under src/ (the scope Coding-Style.md governs) ---
$normalized = $filePath -replace '\\', '/'
if ($normalized -notmatch '/src/.+\.(ps1|psm1|cs)$') { exit 0 }
if (-not (Test-Path -LiteralPath $filePath)) { exit 0 }

$lines = [System.IO.File]::ReadAllLines($filePath)

# --- Collect the line number of every full-line comment ---
# Trailing comments (code then #) don't count; only comment-led lines form a block.
$commentLines = [System.Collections.Generic.List[int]]::new()

if ($filePath -match '\.cs$') {
    # C#: plain // lines; /// XML doc and /* */ blocks are exempt.
    $inBlock = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($inBlock) { if ($t -match '\*/') { $inBlock = $false }; continue }
        if ($t.StartsWith('/*')) { if ($t -notmatch '\*/') { $inBlock = $true }; continue }
        if ($t.StartsWith('//') -and -not $t.StartsWith('///')) { $commentLines.Add($i + 1) }
    }
}
else {
    # PowerShell: tokenize so here-string bodies and <# #> help blocks aren't miscounted.
    $errs = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize(($lines -join "`n"), [ref]$errs)
    foreach ($tok in $tokens) {
        if ($tok.Type -ne 'Comment' -or $tok.Content.StartsWith('<#')) { continue }
        $ln = $lines[$tok.StartLine - 1]
        $lead = $ln.Substring(0, [Math]::Min($tok.StartColumn - 1, $ln.Length))
        if ($lead -match '^\s*$') { $commentLines.Add($tok.StartLine) }
    }
}

# --- Report the first line of each 3+ line comment run ---
$runs = [System.Collections.Generic.List[int]]::new()
$start = 0; $len = 0; $prev = -99
foreach ($n in ($commentLines | Sort-Object -Unique)) {
    if ($n -eq $prev + 1) { $len++ }
    else { if ($len -ge 3) { $runs.Add($start) }; $start = $n; $len = 1 }
    $prev = $n
}
if ($len -ge 3) { $runs.Add($start) }

$leaf = Split-Path $filePath -Leaf
if ($runs.Count -eq 0) {
    Write-Host "[style-hook] ${leaf}: comment cap OK"
    exit 0
}

$hits = ($runs | ForEach-Object { "${leaf}:$_" }) -join ', '
$context = "Comment cap exceeded (Coding-Style.md: one line preferred, two maximum) - " +
"3+ consecutive comment lines starting at $hits. Trim to <=2 lines, or move the longer " +
"rationale into the file's .NOTES block (PowerShell) and reference it from a short inline note."

@{
    systemMessage      = "[DONUT] Comment over the 2-line cap in $leaf ($hits)"
    hookSpecificOutput = @{
        hookEventName     = 'PostToolUse'
        additionalContext = $context
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output
exit 0
