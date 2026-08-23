using namespace Donut.Mvvm

<#
.SYNOPSIS
    View-model backing the temp-password reset overlay.

.DESCRIPTION
    Holds the target user (sam/domain/UPN/display name), the temporary password,
    and the change-at-next-logon flag. MainPresenter fills the target via
    SetTarget when a finder row's Reset action fires, wires the four commands,
    and clears the secret on close. Password is plaintext by design - it is a
    visible reveal-then-copy field like the BitLocker key - but it lives only in
    this VM and is wiped by ClearSecrets; it must never reach a logger or disk.
#>
class ResetPasswordViewModel : ObservableObject {
    [string] $TargetSam = ''
    [string] $TargetDomain = ''
    [string] $TargetDn = ''
    [string] $TargetUpn = ''
    [string] $DisplayName = ''
    [string] $Password = ''
    [string] $PasswordError = ''          # the rule the field failed, shown under it
    [bool]   $HasPasswordError = $false
    [bool]   $ChangeAtLogon = $true       # Good Defaults: temp passwords force a change
    [bool]   $IsBusy = $false
    [object] $GenerateCommand
    [object] $CopyCommand
    [object] $ShowQrCommand
    [object] $ApplyCommand

    # Arms the overlay for a finder user row, with fresh defaults on every open.
    [void] SetTarget([object]$user) {
        if ($null -eq $user) { return }
        $this.Set('TargetSam', [string]$user.SamAccountName)
        $this.Set('TargetDomain', [string]$user.Domain)
        $this.Set('TargetDn', [string]$user.DistinguishedName)
        $this.Set('TargetUpn', [string]$user.UserPrincipalName)
        $name = [string]$user.DisplayName
        $this.Set('DisplayName', $(if ($name) { $name } else { [string]$user.Name }))
        $this.ClearSecrets()
        $this.Set('ChangeAtLogon', $true)
        $this.Set('IsBusy', $false)
    }

    [void] ClearSecrets() {
        $this.Set('Password', '')
        $this.SetPasswordError('')
    }

    # An empty message clears the error; HasPasswordError is what the view collapses on.
    [void] SetPasswordError([string]$message) {
        $this.Set('PasswordError', [string]$message)
        $this.Set('HasPasswordError', -not [string]::IsNullOrWhiteSpace($message))
    }
}
