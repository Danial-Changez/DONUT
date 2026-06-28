using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string]$Sam,
    [string]$Domain
)

$ErrorActionPreference = 'Stop'

# Unlocks a locked-out user off the UI thread (runspace pool). Unlock-ADAccount
# lives in the AD module, so import it here; the service swallows/logs failures
# and returns the bool we emit back to HomePresenter.
Import-Module ActiveDirectory -ErrorAction Stop
$svc = [ActiveDirectoryService]::new(@(), $null)
$user = [AdSearchResult]::new()
$user.Kind = 'User'
$user.SamAccountName = $Sam
$user.Domain = $Domain
[bool]$svc.UnlockUser($user)
