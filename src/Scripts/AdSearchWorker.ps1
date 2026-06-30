<#
.SYNOPSIS
    Runspace-pool worker for the live AD finder — searches one or more forests.

.DESCRIPTION
    Runs the unit-tested multi-forest ActiveDirectoryService.Search off the UI
    thread and emits plain PSCustomObjects so results cross the runspace boundary
    without class-identity coupling. Invoked by HomePresenter's debounced search,
    one job per forest; a down or untrusted forest is skipped inside the service.

.PARAMETER Domains
    Forest/domain DNS names to query.

.PARAMETER Prefix
    The typed search prefix (matched against computers and users).
#>
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string[]]$Domains,
    [string]$Prefix
)

$ErrorActionPreference = 'Stop'

$svc = [ActiveDirectoryService]::new($Domains, $null)
foreach ($r in $svc.Search($Prefix)) {
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
