<#
.SYNOPSIS
    Runspace-pool worker for the live AD finder - searches one or more forests.

.DESCRIPTION
    Runs the unit-tested multi-forest ActiveDirectoryService.Search off the UI
    thread and emits plain PSCustomObjects so results cross the runspace boundary
    without class-identity coupling. Invoked by HomePresenter's debounced search,
    one job per forest; a down or untrusted forest is skipped inside the service.

.PARAMETER Domains
    Forest/domain DNS names to query.

.PARAMETER Prefix
    The typed search prefix (matched against computers and users).

.NOTES
    Emits an 'AdTiming' Information record carrying three raw numbers - this script's start
    ticks, the Search() elapsed, and its end ticks. The worker cannot see the pool queue wait
    ahead of it or the poll lag behind it, and the parent cannot see the LDAP round trip, so
    each reports what it can and FinderPresenter.DescribeSearchTiming does the arithmetic.
    Both run in the same process on the same clock, so there is no skew to correct.

    Information rather than the pipeline: the success stream is the typed row contract the
    caller maps, and Warning already carries per-forest failures.
#>
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string[]]$Domains,
    [string]$Prefix
)

$ErrorActionPreference = 'Stop'

# First statement on purpose: the gap back to the parent's dispatch stamp is the pool queue
# wait plus this script's using-module compile, and neither side can see it alone.
$startedAt = [datetime]::UtcNow

$svc = [ActiveDirectoryService]::new($Domains, $null)
$searchTimer = [System.Diagnostics.Stopwatch]::StartNew()
$hits = $svc.Search($Prefix)
$searchTimer.Stop()
# The warning stream, not the pipeline: results are typed rows the caller maps, and a
# forest that could not answer must not read as a forest that matched nothing.
foreach ($problem in $svc.LastErrors) { Write-Warning $problem }
foreach ($r in $hits) {
    [PSCustomObject]@{
        Kind              = $r.Kind
        Name              = $r.Name
        SamAccountName    = $r.SamAccountName
        UserPrincipalName = $r.UserPrincipalName
        DisplayName       = $r.DisplayName
        Domain            = $r.Domain
        Enabled           = $r.Enabled
        LockedOut         = $r.LockedOut
        DistinguishedName = $r.DistinguishedName
    }
}
# Last, so the end stamp covers building the rows above. Information, not the pipeline: the
# success stream is the typed row contract the caller maps - see .NOTES.
Write-Information -Tags 'AdTiming' -MessageData (
    "$($startedAt.Ticks) $($searchTimer.ElapsedMilliseconds) $([datetime]::UtcNow.Ticks)")
