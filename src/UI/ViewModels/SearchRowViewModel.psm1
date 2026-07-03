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
    UnlockCommand for locked users) are attached by the presenter after construction,
    closing over its handlers - same pattern as HostViewModel's Run/Gather commands.

.NOTES
    Values are computed once per render (the whole collection is swapped), so no
    INotifyPropertyChanged is needed. WPF-free, so the mapping is unit-tested headless.
#>
class SearchRowViewModel {
    [bool]   $IsHeader = $false
    [string] $HeaderText = ''
    [string] $Primary = ''
    [string] $Secondary = ''
    [bool]   $IsComputer = $false
    [bool]   $CanUnlock = $false
    [object] $Result        # the raw worker row, for the presenter's handlers
    [object] $PickCommand   # RelayCommand (computers), assigned by the presenter
    [object] $UnlockCommand # RelayCommand (locked users), assigned by the presenter

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
        $vm.Result = $r
        if ([string]$r.Kind -eq 'User') {
            $label = if (-not [string]::IsNullOrWhiteSpace($r.UserPrincipalName)) { [string]$r.UserPrincipalName } else { [string]$r.SamAccountName }
            if ($r.LockedOut) { $label = $label + " `u{1F512}" }
            $vm.Primary = $label
            $sub = @([string]$r.DisplayName, [string]$r.Domain) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $vm.Secondary = ($sub -join '  -  ')
            $vm.CanUnlock = [bool]$r.LockedOut
        }
        else {
            $vm.Primary = [string]$r.Name
            $vm.Secondary = "$([string]$r.Domain)  -  computer"
            $vm.IsComputer = $true
        }
        return $vm
    }
}
