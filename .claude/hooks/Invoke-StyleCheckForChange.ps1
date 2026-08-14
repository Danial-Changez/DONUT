#Requires -Version 7
<#
.SYNOPSIS
    PostToolUse hook: flags comment blocks over the line cap in edited source files.

.DESCRIPTION
    Reads the Claude Code hook payload (JSON) from stdin and, for edited PowerShell,
    C#, web, and XAML files anywhere in the repo, reports comment blocks longer than
    docs/development/coding-style.md allows: one line, or two directly above a file
    header, a class, or a method or function definition. Violations surface via
    hookSpecificOutput.additionalContext so the comment is trimmed, or its rationale
    moved to .NOTES, immediately rather than in review.

.NOTES
    The rule itself lives in tools/CommentRules.ps1, shared with the repo-wide
    sweep in tools/Invoke-Lint.ps1, so the hook and the lint can never drift.
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
if ($normalized -notmatch '\.(ps1|psm1|cs|mjs|js|ts|astro|xaml)$') { exit 0 }
if ($normalized -match '/(bin|obj|\.cache|node_modules|dist|\.astro|\.diag)/') { exit 0 }
if (-not (Test-Path -LiteralPath $filePath)) { exit 0 }

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tools/CommentRules.ps1')
$runs = @(Get-CommentFinding -Files (Get-Item -LiteralPath $filePath))

$leaf = Split-Path $filePath -Leaf
if ($runs.Count -eq 0) {
    Write-Host "[style-hook] ${leaf}: comment cap OK"
    exit 0
}

$hits = ($runs | ForEach-Object { "$($_.File):$($_.Line)" }) -join ', '
$context = 'Comment cap exceeded (docs/development/coding-style.md: one line, two only ' +
"above a file header, class, or method) at $hits. Trim to one line, delete the comment " +
'if it only narrates the code, or move real rationale into .NOTES with a short pointer.'

@{
    systemMessage      = "[DONUT] Comment over the line cap in $leaf ($hits)"
    hookSpecificOutput = @{
        hookEventName     = 'PostToolUse'
        additionalContext = $context
    }
} | ConvertTo-Json -Depth 5 -Compress | Write-Output
exit 0
