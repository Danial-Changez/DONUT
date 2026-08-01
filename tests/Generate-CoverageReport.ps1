<#
.SYNOPSIS
    Runs the suite with code coverage and renders an HTML report site.

.DESCRIPTION
    Runs the tests on the pinned Pester 5 (tools/Import-PinnedPester.ps1) with
    Pester's built-in JaCoCo coverage output, then renders coverage.xml into an
    HTML site under CoverageReport/ using ReportGenerator. When ReportGenerator
    is not already on PATH it is installed automatically as a repo-local dotnet
    tool under tools/.cache/reportgenerator (requires the .NET SDK).

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).

.PARAMETER ReportDir
    Output directory for the HTML site. Defaults to CoverageReport/.
#>
param(
    [string[]] $Path = @($PSScriptRoot),
    [string] $ReportDir = (Join-Path $PSScriptRoot '..' 'CoverageReport')
)

$ErrorActionPreference = 'Stop'

# WPF integration tests need an STA thread; the relaunch is Windows-only
# because apartment state does not exist elsewhere (and would loop forever).
if ($IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host 'Re-launching in STA mode for WPF tests...' -ForegroundColor Yellow
    pwsh -Sta -File $MyInvocation.MyCommand.Path @PSBoundParameters
    exit $LASTEXITCODE
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $repoRoot 'tools' 'Import-PinnedPester.ps1')

$coverageXml = Join-Path $repoRoot 'coverage.xml'

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
$config.CodeCoverage.Enabled = $true
# Profiler-based tracer (the Pester 6 default), much faster than v5's
# breakpoint collector. Flip to $true if coverage numbers ever look off.
$config.CodeCoverage.UseBreakpoints = $false
$config.CodeCoverage.OutputFormat = 'JaCoCo'
$config.CodeCoverage.OutputPath = $coverageXml
# Coverage measures the product modules, not the test tree itself.
$config.CodeCoverage.Path = @('Core', 'Models', 'Services') |
    ForEach-Object { Join-Path $repoRoot 'src' $_ }

Write-Host 'Running tests with code coverage...' -ForegroundColor Cyan
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

Write-Host 'Rendering HTML report with ReportGenerator...' -ForegroundColor Cyan
reportgenerator `
    "-reports:$coverageXml" `
    "-targetdir:$ReportDir" `
    "-sourcedirs:$(Join-Path $repoRoot 'src')" `
    '-reporttypes:Html' `
    '-title:DONUT'
if ($LASTEXITCODE -ne 0) {
    Write-Error "ReportGenerator failed with exit code $LASTEXITCODE."
}

Write-Host "Report generated at: $(Join-Path $ReportDir 'index.html')" -ForegroundColor Green
