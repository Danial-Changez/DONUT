#Requires -Version 7
<#
.SYNOPSIS
    PostToolUse hook: flags comment blocks over the line cap in edited source files.

.DESCRIPTION
    Reads the Claude Code hook payload (JSON) from stdin and, for edited PowerShell
    and C# files anywhere in the repo, reports comment blocks longer than
    docs/development/coding-style.md allows: one line, or two directly above a file
    header, a class, or a method or function definition. Violations surface via
    hookSpecificOutput.additionalContext so the comment is trimmed, or its rationale
    moved to .NOTES, immediately rather than in review.

.NOTES
    Exemptions match tools/Invoke-Lint.ps1, which sweeps the same rule repo-wide:
    - Comment-based help and C# /// doc comments may span any number of lines.
    - A dashed list may run long when it replaces denser prose.
    - Here-string bodies are payload, not commentary, so they never count.
#>

$ErrorActionPreference = 'Stop'

$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$filePath = $payload.tool_input.file_path
if (-not $filePath) { $filePath = $payload.tool_response.filePath }
if (-not $filePath) { exit 0 }

# The rule is repo-wide, so only build output is out of scope.
$normalized = $filePath -replace '\\', '/'
if ($normalized -notmatch '\.(ps1|psm1|cs|mjs|js|ts|astro)$') { exit 0 }
if ($normalized -match '/(bin|obj|\.cache|node_modules|dist|\.astro|\.diag)/') { exit 0 }
if (-not (Test-Path -LiteralPath $filePath)) { exit 0 }

$lines = [System.IO.File]::ReadAllLines($filePath)
# Everything but PowerShell uses // comments and the same brace-language shapes.
$isCs = $normalized -notmatch '\.(ps1|psm1)$'

# Trailing comments (code then #) do not count, only comment-led lines form a block.
$commentLines = [System.Collections.Generic.List[int]]::new()

if ($isCs) {
    $inBlock = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $t = $lines[$i].Trim()
        if ($inBlock) { if ($t -match '\*/') { $inBlock = $false }; continue }
        if ($t.StartsWith('/*')) { if ($t -notmatch '\*/') { $inBlock = $true }; continue }
        if ($t.StartsWith('//') -and -not $t.StartsWith('///')) { $commentLines.Add($i + 1) }
    }
}
else {
    # Tokenized so here-string bodies and <# #> help blocks are not miscounted.
    $errs = $null
    $tokens = [System.Management.Automation.PSParser]::Tokenize(($lines -join "`n"), [ref]$errs)
    foreach ($tok in $tokens) {
        if ($tok.Type -ne 'Comment' -or $tok.Content.StartsWith('<#')) { continue }
        $ln = $lines[$tok.StartLine - 1]
        $lead = $ln.Substring(0, [Math]::Min($tok.StartColumn - 1, $ln.Length))
        if ($lead -match '^\s*$') { $commentLines.Add($tok.StartLine) }
    }
}

$csExempt = '^\s*(namespace|#nullable|export|import|const|function|class)|' +
'^\s*((public|internal|sealed|static|abstract|partial)\s+)*(class|record|struct|interface|enum)\s'
$psExempt = '^\s*(class|enum|function)\s|' +
'^\s*(hidden\s+)?(static\s+)?(\[[\w\.\[\]]+\]\s*)?[\w-]+\s*\('
$exemptNext = if ($isCs) { $csExempt } else { $psExempt }
$marker = if ($isCs) { '//' } else { '#' }

# Reports the first line of every run that exceeds its own allowance.
function Test-Run([int] $start, [int] $len) {
    if ($len -lt 2) { return $false }
    $body = $lines[($start - 1)..($start + $len - 2)]
    if (@($body -match "^\s*$marker\s+-\s").Count -ge 2) { return $false }
    $next = if ($start + $len - 1 -lt $lines.Count) { $lines[$start + $len - 1] } else { '' }
    $limit = if ($start -eq 1 -or $next -match $exemptNext) { 2 } else { 1 }
    return $len -gt $limit
}

$runs = [System.Collections.Generic.List[string]]::new()
$start = 0; $len = 0; $prev = -99
foreach ($n in ($commentLines | Sort-Object -Unique)) {
    if ($n -eq $prev + 1) { $len++ }
    else {
        if (Test-Run $start $len) { $runs.Add("${start}") }
        $start = $n; $len = 1
    }
    $prev = $n
}
if (Test-Run $start $len) { $runs.Add("${start}") }

$leaf = Split-Path $filePath -Leaf
if ($runs.Count -eq 0) {
    Write-Host "[style-hook] ${leaf}: comment cap OK"
    exit 0
}

$hits = ($runs | ForEach-Object { "${leaf}:$_" }) -join ', '
$context = 'Comment cap exceeded (docs/development/coding-style.md: one line, two only ' +
"above a file header, class, or method) at $hits. Trim to one line, delete the comment " +
"if it only narrates the code, or move real rationale into .NOTES with a short pointer."

@{
    systemMessage      = "[DONUT] Comment over the line cap in $leaf ($hits)"
    hookSpecificOutput = @{
        hookEventName     = 'PostToolUse'
        additionalContext = $context
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output
exit 0
