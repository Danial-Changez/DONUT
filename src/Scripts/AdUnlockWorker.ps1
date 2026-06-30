<#
.SYNOPSIS
    Runspace-pool worker that unlocks a locked-out AD user account.

.DESCRIPTION
    Runs ActiveDirectoryService.UnlockUser off the UI thread. Imports the
    ActiveDirectory module (for Unlock-ADAccount) here in the worker; the service
    swallows and logs failures and returns the bool this worker emits back to
    HomePresenter.

.PARAMETER Sam
    sAMAccountName of the user to unlock.

.PARAMETER Domain
    The user's home domain, used as the LDAP server target.
#>
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string]$Sam,
    [string]$Domain
)

$ErrorActionPreference = 'Stop'

Import-Module ActiveDirectory -ErrorAction Stop
$svc = [ActiveDirectoryService]::new(@(), $null)
$user = [AdSearchResult]::new()
$user.Kind = 'User'
$user.SamAccountName = $Sam
$user.Domain = $Domain
[bool]$svc.UnlockUser($user)
