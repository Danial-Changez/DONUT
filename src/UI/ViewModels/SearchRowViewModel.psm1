<#
.SYNOPSIS
    Display-ready row for the AD finder dropdown.

.DESCRIPTION
    One flat collection drives the whole dropdown: section headers and result rows are
    both SearchRowViewModels, distinguished by IsHeader; the single DataTemplate shows
    the header text or the row chrome via triggers. Label rules: users show UPN
    (SamAccountName fallback) with a lock glyph when locked out and
    "DisplayName - Domain" underneath; computers show the machine name over
    "Domain - computer" and are pickable. Commands (PickCommand for computers,
    UnlockCommand for locked users, ResetCommand for any user) are attached by the
    presenter after construction, closing over its handlers - same pattern as
    HostViewModel's Run/Gather commands.

.NOTES
    Values are computed once per render (the whole collection is swapped), so no
    INotifyPropertyChanged is needed. WPF-free, so the mapping is unit-tested headless.
#>
class SearchRowViewModel {
    [bool]   $IsHeader = $false
    [string] $HeaderText = ''
    [string] $Primary = ''
    [string] $Secondary = ''
    [bool]   $CanUnlock = $false
    [bool]   $CanReset = $false   # any user row: password reset is not lock-gated
    [object] $PickCommand   # RelayCommand (computers), assigned by the presenter
    [object] $UnlockCommand # RelayCommand (locked users), assigned by the presenter
    [object] $ResetCommand  # RelayCommand (users), assigned by the presenter

    # A section header row ("COMPUTERS" / "USERS").
    static [SearchRowViewModel] Header([string]$text) {
        $vm = [SearchRowViewModel]::new()
        $vm.IsHeader = $true
        $vm.HeaderText = $text
        return $vm
    }

    # A result row from an AdSearchWorker hit (Kind = 'Computer' | 'User').
    static [SearchRowViewModel] FromResult([object]$r) {
        $vm = [SearchRowViewModel]::new()
        if ([string]$r.Kind -eq 'User') {
            $label = if ([string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.SamAccountName }
            else { [string]$r.UserPrincipalName }
            # ASCII suffix, not a glyph: the row template pins no symbol font (tofu risk).
            if ($r.LockedOut) { $label = $label + '  (locked)' }
            $vm.Primary = $label
            $sub = @([string]$r.DisplayName, [string]$r.Domain) |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $vm.Secondary = ($sub -join '  -  ')
            $vm.CanUnlock = [bool]$r.LockedOut
            $vm.CanReset = $true
        } else {
            $vm.Primary = [string]$r.Name
            $vm.Secondary = "$([string]$r.Domain)  -  computer"
        }
        return $vm
    }
}
