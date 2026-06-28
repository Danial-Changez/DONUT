using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string[]]$Domains,
    [string]$Prefix
)

$ErrorActionPreference = 'Stop'

# Live AD finder worker: runs the (unit-tested) multi-forest search on the
# runspace pool and emits plain PSCustomObjects so results cross the runspace
# boundary without class-identity coupling. Invoked by HomePresenter's debounced
# search; a down/untrusted forest is skipped inside the service.
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
