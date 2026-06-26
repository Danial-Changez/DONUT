#Requires -Version 7
<#
.SYNOPSIS
    PostToolUse hook: runs the matching Pester unit test when a DONUT logic
    module under src/Core, src/Models, or src/Services is edited.

.DESCRIPTION
    Reads the Claude Code hook payload (JSON) from stdin, extracts the edited
    file path, and — only for logic modules (*.psm1 under Core/Models/Services) —
    runs the matching tests/Unit/<Module>.Tests.ps1. Falls back to the full unit
    suite when no matching test file exists. On failure it surfaces the result
    back to the model via hookSpecificOutput.additionalContext so the regression
    is acted on immediately. Edits to UI, tests, scripts, or docs are ignored.
#>

$ErrorActionPreference = 'Stop'

# --- Read the hook payload from stdin ---
$raw = [Console]::In.ReadToEnd()
if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

try { $payload = $raw | ConvertFrom-Json } catch { exit 0 }

$filePath = $payload.tool_input.file_path
if (-not $filePath) { $filePath = $payload.tool_response.filePath }
if (-not $filePath) { exit 0 }

# --- Act only on logic modules under src/{Core,Models,Services} ---
$normalized = $filePath -replace '\\', '/'
if ($normalized -notmatch '/src/(Core|Models|Services)/[^/]+\.psm1$') { exit 0 }

$moduleName = [System.IO.Path]::GetFileNameWithoutExtension($filePath)

# --- Resolve repo root (.claude/hooks -> repo) and the matching test target ---
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$unitDir  = Join-Path $repoRoot 'tests/Unit'
$testFile = Join-Path $unitDir "$moduleName.Tests.ps1"

if (Test-Path $testFile) {
    $target = $testFile
    $label  = "$moduleName.Tests.ps1"
}
else {
    $target = $unitDir
    $label  = "full unit suite (no matching test for $moduleName)"
}

# --- Run Pester ---
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$config = [PesterConfiguration]::Default
$config.Run.Path        = $target
$config.Run.PassThru    = $true
$config.Output.Verbosity = 'None'
$result = Invoke-Pester -Configuration $config

$summary = "$($result.PassedCount) passed, $($result.FailedCount) failed, $($result.SkippedCount) skipped"

if ($result.FailedCount -gt 0) {
    $failed = $result.Failed | ForEach-Object { $_.ExpandedPath } | Select-Object -First 10
    $context = "Pester ($label) after editing ${moduleName}: $summary`nFailing tests:`n - " + ($failed -join "`n - ")
    @{
        systemMessage      = "[DONUT] $moduleName tests FAILED: $summary"
        hookSpecificOutput = @{
            hookEventName     = 'PostToolUse'
            additionalContext = $context
        }
    } | ConvertTo-Json -Depth 5 -Compress | Write-Output
    exit 0
}

Write-Host "[pester-hook] $moduleName -> $label : $summary"
exit 0
