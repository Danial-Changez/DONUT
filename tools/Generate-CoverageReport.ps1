<#
.SYNOPSIS
    Runs the suite with code coverage and renders an HTML report site.

.DESCRIPTION
    Runs the tests on the pinned Pester 6 (tools/Import-PinnedPester.ps1) with
    Pester's built-in coverage output, then renders coverage.xml into an HTML
    site under CoverageReport/ using ReportGenerator. When ReportGenerator is
    not already on PATH it is installed automatically as a repo-local dotnet
    tool under tools/.cache/reportgenerator (requires the .NET SDK).

    When REPORTGENERATOR_LICENSE is set (process env, or the Windows User or
    Machine scope for shells opened before the variable was added), it is
    passed to ReportGenerator so licensed (PRO) features are available.

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).

.PARAMETER ReportDir
    Output directory for the HTML site. Defaults to CoverageReport/.

.PARAMETER Format
    Coverage XML format: JaCoCo (default) or Cobertura. ReportGenerator renders
    either; pick whichever a downstream consumer (CI, IDE plugin) expects.
#>
param(
    [string[]] $Path = @(Join-Path $PSScriptRoot '..' 'tests'),
    [string] $ReportDir = (Join-Path $PSScriptRoot '..' 'CoverageReport'),
    [ValidateSet('JaCoCo', 'Cobertura')]
    [string] $Format = 'JaCoCo'
)

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# WPF integration tests need an STA thread, and (like Invoke-Tests.ps1) a session
# holding repo modules would test stale classes - both get a clean child pwsh.
$staleModules = Get-Module | Where-Object {
    $_.Path -and $_.Path.StartsWith($repoRoot, [System.StringComparison]::OrdinalIgnoreCase)
}
$needSta = $IsWindows -and [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'
if ($needSta -or $staleModules) {
    Write-Host 'Re-launching in a clean pwsh (STA for WPF tests)...' -ForegroundColor Yellow
    $staArgs = if ($IsWindows) { @('-Sta') } else { @() }
    & ([System.Environment]::ProcessPath) @staArgs -File $MyInvocation.MyCommand.Path @PSBoundParameters
    exit $LASTEXITCODE
}

. (Join-Path $PSScriptRoot 'Import-PinnedPester.ps1')

$coverageXml = Join-Path $repoRoot 'coverage.xml'

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Normal'
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
