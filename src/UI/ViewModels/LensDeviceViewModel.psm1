using namespace Donut.Mvvm
using module "..\..\Models\PersonLens.psm1"

<#
.SYNOPSIS
    One device row in the user Lens: a person's SCCM machine + its BitLocker key.

.DESCRIPTION
    Renders a LensDevice - name, OS, relative last domain logon - with the BitLocker
    recovery key hidden until revealed (it's a recovery secret). RevealCommand is
    self-wired (pure UI state: flips IsBitLockerRevealed); AddCommand and ShowQrCommand
    are wired by FinderPresenter (drop the WSID into the machine list / pop the QR
    overlay for LatestKey). Inherits ObservableObject so the reveal updates live.
#>
class LensDeviceViewModel : ObservableObject {
    [string] $Name = ''
    [string] $Os = ''
    [string] $LastSeenText = ''
    [string] $Domain = ''
    [string] $BitLockerText = ''          # the joined keys; shown only once revealed
    [string] $LatestKey = ''              # newest recovery password (by Created); QR payload
    [bool]   $HasBitLocker = $false
    [bool]   $IsBitLockerRevealed = $false
    [string] $Note = ''
    [object] $RevealCommand               # RelayCommand: reveal the BitLocker key(s)
    # RelayCommand: add the WSID to the machine list (presenter-wired).
    [object] $AddCommand
    # RelayCommand: show a QR of LatestKey in the shell overlay (presenter-wired).
    [object] $ShowQrCommand

    LensDeviceViewModel([LensDevice]$d) {
        if ($null -ne $d) {
            $this.Name = $d.Name
            $this.Os = $d.Os
            $this.Domain = $d.Domain
            $this.Note = $d.Note
            $this.LastSeenText = [LensFormat]::LogonLabel($d.LastLogon)
            $this.HasBitLocker = $d.HasBitLocker()
            $this.BitLockerText = (@($d.BitLockerKeys | ForEach-Object {
                        if ($_.Created) { "$($_.Password)  ($($_.Created))" } else { $_.Password }
                    }) -join "`n")
            # Newest key wins. Created is agent-normalized ISO8601; parse to a DateTime and
            # compare chronologically (unparseable/blank sorts earliest, so a dated rotation
            # supersedes an undated one). A later key at the same instant still wins the tie.
            $latest = $null
            $latestAt = [datetime]::MinValue
            foreach ($k in $d.BitLockerKeys) {
                $at = [datetime]::MinValue
                [void][datetime]::TryParse([string]$k.Created,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
                if ($null -eq $latest -or $at -ge $latestAt) {
                    $latest = $k
                    $latestAt = $at
                }
            }
            if ($null -ne $latest) { $this.LatestKey = $latest.Password }
        }
        $self = $this
        $reveal = { param($p) $self.Set('IsBitLockerRevealed', $true) }.GetNewClosure()
        $this.RevealCommand = [RelayCommand]::new([System.Action[object]]$reveal)
    }
}
