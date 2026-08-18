<#
.SYNOPSIS
    Runspace-pool worker that resets an AD user's password to a temporary one.

.DESCRIPTION
    Runs ActiveDirectoryService.ResetPassword off the UI thread; the service swallows
    and logs failures and returns the bool this worker emits back to MainPresenter.
    Nothing is imported: the reset writes through System.DirectoryServices, so the
    RSAT module this worker used to require is no longer on the path at all.

.PARAMETER Sam
    sAMAccountName of the user to reset.

.PARAMETER Domain
    The user's home domain, used as the LDAP server target.

.PARAMETER Password
    The temporary password. SecureString end-to-end: the pool runs in-process,
    so the instance built by TempPassword.ToSecure arrives intact.

.PARAMETER ChangeAtLogon
    Whether the account must change this password at next logon.
#>
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Models\AdSearchResult.psm1"

param(
    [string]$Sam,
    [string]$Domain,
    [securestring]$Password,
    [bool]$ChangeAtLogon
)

$ErrorActionPreference = 'Stop'

$svc = [ActiveDirectoryService]::new(@(), $null)
$user = [AdSearchResult]::new()
$user.Kind = 'User'
$user.SamAccountName = $Sam
$user.Domain = $Domain
[bool]$svc.ResetPassword($user, $Password, $ChangeAtLogon)
