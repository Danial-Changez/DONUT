<#
.SYNOPSIS
    Runs the DONUT test suite on the pinned Pester major version (5.x).

.DESCRIPTION
    The suite is written for Pester 5 syntax. A bare `Invoke-Pester` binds to
    whichever Pester wins module resolution on the machine - and on boxes that
    carry the built-in Windows PowerShell Pester 3.4.0 and/or a user-scoped
    Pester 6+, the v3 commands (Describe/Should/Mock) can shadow mid-run, after
    which EVERY remaining test fails with errors like "'-Be' is not a valid
    Should operator" or "The Mock command may only be used inside a Describe
    block". Those failures are a tooling artifact, not product regressions.

    This runner unloads any other Pester from the session, imports the newest
    installed Pester 5.5+, and fails with install guidance when none exists -
    it never silently falls back to another major version.

.PARAMETER Path
    Test path(s) to run. Defaults to the full suite (tests/).
#>
param([string[]] $Path = @('tests'))

$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -eq 5 -and $_.Version -ge [version]'5.5.0' } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    Write-Error (
        "Pester 5.5+ is required (this suite uses Pester 5 syntax; v3/v4/v6 will not " +
        "run it). Install it with:`n" +
        "  Install-Module Pester -RequiredVersion 5.7.1 -Scope CurrentUser -Force")
    exit 1
}

# Unload any already-loaded Pester (e.g. a v6 auto-import) so two majors never
# coexist in one session - coexistence is exactly how v3 commands shadow a run.
Get-Module -Name Pester | Remove-Module -Force
Import-Module Pester -RequiredVersion $pester.Version -Force

$config = New-PesterConfiguration
$config.Run.Path = $Path
$config.Run.Exit = $true
$config.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $config
