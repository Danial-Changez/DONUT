<#
.SYNOPSIS
    Runs the DONUT test suite on the pinned Pester major version (6.x).

.DESCRIPTION
    Imports the pinned Pester 6 via tools/Import-PinnedPester.ps1 (see that
    script for why the suite must never run under Pester 3/4/5), then runs
    the requested test paths with the standard configuration.

    With -Coverage, the same run also collects Pester's code coverage over
    src/{Core,Models,Services} and renders coverage.xml into an HTML site
    using ReportGenerator. When ReportGenerator is not already on PATH it is
    installed automatically as a repo-local dotnet tool under
    tools/.cache/reportgenerator (requires the .NET SDK). When
    REPORTGENERATOR_LICENSE is set (process env, or the Windows User or
    Machine scope for shells opened before the variable was added), it is
    passed to ReportGenerator so licensed (PRO) features are available.

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).

.PARAMETER FailFast
    Stop the whole run at the first failing test (Run.SkipRemainingOnFailure).
    A tight fix-and-rerun loop for local work; leave off for CI and pre-push
    runs so every failure is visible.

.PARAMETER Coverage
    Collect code coverage and render the HTML report site. Coverage is
    informational: test failures are reported but do not abort the render.

.PARAMETER ReportDir
    Output directory for the HTML site (only with -Coverage). Defaults to
    CoverageReport/.

.PARAMETER Format
    Coverage XML format (only with -Coverage): JaCoCo (default) or Cobertura.
    ReportGenerator renders either; pick whichever a downstream consumer
    (CI, IDE plugin) expects.
#>
param(
    [string[]] $Path = @('tests'),
    [switch] $FailFast,
    [switch] $Coverage,
    [string] $ReportDir,
    [ValidateSet('JaCoCo', 'Cobertura')]
    [string] $Format = 'JaCoCo'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
if (-not $ReportDir) { $ReportDir = Join-Path $repoRoot 'CoverageReport' }

# using module never reloads an already-imported module, so a session that has
# run the suite (or the app) before an edit would test STALE classes silently.
# The WPF integration tests additionally need an STA thread - on an MTA host
# they self-skip and the "full suite" quietly stops covering them. Either
# condition gets a clean child pwsh (-Sta on Windows).
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
    $cmd += " -ReportDir '$($ReportDir -replace "'", "''")' -Format $Format"
    if ($FailFast) { $cmd += ' -FailFast' }
    if ($Coverage) { $cmd += ' -Coverage' }
    $staArgs = if ($IsWindows) { @('-Sta') } else { @() }
    & ([System.Environment]::ProcessPath) @staArgs -NoProfile -Command $cmd
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot 'Import-PinnedPester.ps1')

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Output.Verbosity = 'Normal'
if ($FailFast) {
    $config.Run.SkipRemainingOnFailure = 'Run'
}

if (-not $Coverage) {
    $config.Run.Exit = $true
    Invoke-Pester -Configuration $config
    return
}

$coverageXml = Join-Path $repoRoot 'coverage.xml'

$config.Run.PassThru = $true
$config.CodeCoverage.Enabled = $true
$config.CodeCoverage.OutputFormat = $Format
$config.CodeCoverage.OutputPath = $coverageXml
# Coverage measures the product modules, not the test tree itself.
$config.CodeCoverage.Path = @('Core', 'Models', 'Services') |
    ForEach-Object { Join-Path $repoRoot 'src' $_ }

Write-Host "Running tests with code coverage ($Format)..." -ForegroundColor Cyan
$result = Invoke-Pester -Configuration $config

if (-not (Test-Path $coverageXml)) {
    Write-Error 'Coverage XML file was not generated.'
}
if ($result.FailedCount -gt 0) {
    Write-Host "$($result.FailedCount) test(s) failed; the report still reflects executed code." -ForegroundColor Yellow
}

# Prefer a machine-wide ReportGenerator; otherwise auto-install a repo-local
# dotnet tool under tools/.cache (gitignored) on first use.
if (-not (Get-Command reportgenerator -ErrorAction SilentlyContinue)) {
    $toolDir = Join-Path $repoRoot 'tools' '.cache' 'reportgenerator'
    if (-not (Test-Path (Join-Path $toolDir 'reportgenerator*'))) {
        if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
            Write-Error (
                "ReportGenerator is required to render the HTML site, and the .NET SDK is " +
                "not available to auto-install it. Either install the SDK and re-run, or " +
                "install the tool yourself and put it on PATH:`n" +
                "  dotnet tool install --global dotnet-reportgenerator-globaltool")
        }
        Write-Host 'Installing ReportGenerator (first run only)...' -ForegroundColor Cyan
        dotnet tool install dotnet-reportgenerator-globaltool --tool-path $toolDir
        if ($LASTEXITCODE -ne 0) {
            Write-Error "dotnet tool install failed with exit code $LASTEXITCODE."
        }
    }
    $env:PATH = "$toolDir$([IO.Path]::PathSeparator)$env:PATH"
}

# ReportGenerator merges into an existing directory; clear it so removed
# modules do not linger in the site between runs.
if (Test-Path $ReportDir) {
    Remove-Item (Join-Path $ReportDir '*') -Recurse -Force
}

$rgArgs = @(
    "-reports:$coverageXml"
    "-targetdir:$ReportDir"
    "-sourcedirs:$repoRoot"
    '-reporttypes:Html'
    '-title:DONUT'
)

# Freshly set User/Machine values are visible here even before a shell restart.
$rgLicense = $env:REPORTGENERATOR_LICENSE
if (-not $rgLicense -and $IsWindows) {
    $rgLicense = @('User', 'Machine') |
        ForEach-Object { [Environment]::GetEnvironmentVariable('REPORTGENERATOR_LICENSE', $_) } |
        Where-Object { $_ } | Select-Object -First 1
}
if ($rgLicense) {
    Write-Host 'Using ReportGenerator license from REPORTGENERATOR_LICENSE.' -ForegroundColor Cyan
    $rgArgs += "-license:$rgLicense"
}

Write-Host 'Rendering HTML report with ReportGenerator...' -ForegroundColor Cyan
reportgenerator @rgArgs
if ($LASTEXITCODE -ne 0) {
    Write-Error "ReportGenerator failed with exit code $LASTEXITCODE."
}

Write-Host "Report generated at: $(Join-Path $ReportDir 'index.html')" -ForegroundColor Green
