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
    [string] $Domain = ''                 # home AD domain, so Add resolves the FQDN first
    [string] $LastSeenText = ''
    [string] $Model = ''
    [string] $TagText = ''                # "Tag <service tag>", where '' collapses the separator
    # $null rather than '' so an unknown OS/manufacturer pair shows no tooltip at all.
    [object] $DetailTip
    [string] $BitLockerText = ''          # the joined keys, shown only once revealed
    [string] $LatestKey = ''              # newest recovery password (by Created), the QR payload
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
            $this.Domain = $d.Domain
            $this.Model = $d.Model
            # "Tag" spelled out matches the MACHINE stat tile, so one fact keeps one name.
            if ($d.Serial) { $this.TagText = "Tag $($d.Serial)" }
            # OS lives in the tooltip: usually shared, but it still spots a Windows 10 holdout.
            $tip = @()
            if ($d.Os) { $tip += $d.Os }
            if ($d.Manufacturer) { $tip += $d.Manufacturer }
            if ($tip.Count -gt 0) { $this.DetailTip = ($tip -join '   ·   ') }
            $this.Note = $d.Note
            $this.LastSeenText = [LensFormat]::LogonLabel($d.LastLogon)
            $this.HasBitLocker = $d.HasBitLocker()
            # Newest-first by parsed Created, blanks last, so LatestKey is the QR's newest key.
            $dated = foreach ($k in $d.BitLockerKeys) {
                $at = [datetime]::MinValue
                [void][datetime]::TryParse([string]$k.Created,
                    [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$at)
                [pscustomobject]@{ Key = $k; At = $at }
            }
            $ordered = @($dated | Sort-Object -Descending -Stable -Property At)
            $this.BitLockerText = (@($ordered | ForEach-Object {
                        if ($_.At -gt [datetime]::MinValue) {
                            "$($_.Key.Password)  ($($_.At.ToString('yyyy-MM-dd HH:mm')))"
                        } elseif ($_.Key.Created) { "$($_.Key.Password)  ($($_.Key.Created))" }
                        else { $_.Key.Password }
                    }) -join "`n")
            if ($ordered.Count -gt 0) { $this.LatestKey = $ordered[0].Key.Password }
        }
        $self = $this
        $reveal = { param($p) $self.Set('IsBitLockerRevealed', $true) }.GetNewClosure()
        $this.RevealCommand = [RelayCommand]::new([System.Action[object]]$reveal)
    }
}
