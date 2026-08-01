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

# using module never reloads an already-imported module, so a session that has
# run the suite (or the app) before an edit would test STALE classes silently.
# The WPF integration tests additionally need an STA thread - on an MTA host
# they self-skip and the "full suite" quietly stops covering them. Either
# condition gets a clean child pwsh (-Sta on Windows).
$repoRoot = Split-Path $PSScriptRoot -Parent
$stale = Get-Module | Where-Object {
    $_.Path -and $_.Path.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
}
$needSta = $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'
if ($stale -or $needSta) {
    $why = if ($stale) { "repo modules already loaded: $($stale.Name -join ', ')" }
    else { 'STA needed for the WPF tests' }
    Write-Host "Relaunching in a clean pwsh ($why)..." -ForegroundColor Yellow
    $quoted = @($Path | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $cmd = "& '$($PSCommandPath -replace "'", "''")' -Path @($quoted)"
    if ($FailFast) { $cmd += ' -FailFast' }
    $staArgs = if ($IsWindows) { @('-Sta') } else { @() }
    & ([System.Environment]::ProcessPath) @staArgs -NoProfile -Command $cmd
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot 'Import-PinnedPester.ps1')

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = 'Normal'
if ($FailFast) {
    $config.Run.SkipRemainingOnFailure = 'Run'
}
Invoke-Pester -Configuration $config
