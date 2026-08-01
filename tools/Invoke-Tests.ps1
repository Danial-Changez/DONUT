<#
.SYNOPSIS
    Runs the DONUT test suite on the pinned Pester major version (5.x).

.DESCRIPTION
    Imports the pinned Pester 5 via tools/Import-PinnedPester.ps1 (see that
    script for why the suite must never run under Pester 3/4/6), then runs
    the requested test paths with the standard configuration.

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).
#>
param([string[]] $Path = @('tests'))

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Import-PinnedPester.ps1')

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $config
