<#
.SYNOPSIS
    Imports the newest installed Pester 6 into the calling session.

.DESCRIPTION
    The suite runs on Pester 6. A bare `Invoke-Pester` binds to whichever
    Pester wins module resolution on the machine - and on boxes that carry
    the built-in Windows PowerShell Pester 3.4.0 and/or a leftover
    user-scoped Pester 5, the older commands (Describe/Should/Mock) can
    shadow mid-run, after which EVERY remaining test fails with errors like
    "'-Be' is not a valid Should operator" or "The Mock command may only be
    used inside a Describe block". Those failures are a tooling artifact,
    not product regressions.

    Dot-source this script to unload any other Pester from the session, import
    the newest installed Pester 6, and fail with install guidance when none
    exists - it never silently falls back to another major version.
#>
$ErrorActionPreference = 'Stop'

$pester = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -eq 6 -and $_.Version -ge [version]'6.0.1' } |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $pester) {
    Write-Error (
        "Pester 6 is required - the suite pins one major so runs are reproducible " +
        "and older Pesters (3.4.0 ships inside Windows PowerShell) never shadow a " +
        "run. Install it with:`n" +
        "  Install-Module Pester -RequiredVersion 6.0.1 -Scope CurrentUser -Force")
    exit 1
}

# Two majors coexisting in one session is exactly how v3 commands shadow a run.
Get-Module -Name Pester | Remove-Module -Force
Import-Module Pester -RequiredVersion $pester.Version -Force
