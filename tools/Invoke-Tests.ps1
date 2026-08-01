<#
.SYNOPSIS
    Runs the DONUT test suite on the pinned Pester major version (6.x).

.DESCRIPTION
    Imports the pinned Pester 6 via tools/Import-PinnedPester.ps1 (see that
    script for why the suite must never run under Pester 3/4/5), then runs
    the requested test paths with the standard configuration.

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).

.PARAMETER FailFast
    Stop the whole run at the first failing test (Run.SkipRemainingOnFailure).
    A tight fix-and-rerun loop for local work; leave off for CI and pre-push
    runs so every failure is visible.
#>
param(
    [string[]] $Path = @('tests'),
    [switch] $FailFast
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Import-PinnedPester.ps1')

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = 'Normal'
if ($FailFast) {
    $config.Run.SkipRemainingOnFailure = 'Run'
}
Invoke-Pester -Configuration $config
