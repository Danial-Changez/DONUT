<#
.SYNOPSIS
    Pure presentation-state mapper for the Home fleet cards.

.DESCRIPTION
    Translates an AsyncJob's (JobType, Status) plus the manual-reboot flag into
    the bits a card needs to render: a human label, a colour resource key, and
    whether the host is still busy (which drives the indeterminate progress
    animation).

.NOTES
    Deliberately free of any WPF dependency so it can be unit-tested off-domain
    and out of process. The presenter consumes the result and pokes the controls.
#>
enum FleetCardState {
    Queued
    Scanning
    Updating
    Reconnecting
    Completed
    RebootRequired
    Failed
}

class FleetCardStatus {
    [FleetCardState] $State
    [string]     $Label
    [string]     $ColorKey   # resource key into UIColors.xaml
    [bool]       $IsBusy     # true => indeterminate progress bar is animating
    [string]     $Glyph      # status symbol so the chip reads by shape, not colour alone

    FleetCardStatus([FleetCardState]$state, [string]$label, [string]$colorKey, [bool]$isBusy,
        [string]$glyph) {
        $this.State    = $state
        $this.Label    = $label
        $this.ColorKey = $colorKey
        $this.IsBusy   = $isBusy
        $this.Glyph    = $glyph
    }

    # Maps a job's coordinates (jobType Scan/UpdateScan/UpdateApply, status Created/
    # Running/Completed/Failed, rebootRequired) to a display status.
    static [FleetCardStatus] FromJob([string]$jobType, [string]$status, [bool]$rebootRequired) {
        switch ($status) {
            'Failed' {
                return [FleetCardStatus]::new(
                    [FleetCardState]::Failed, 'Failed', 'AccentRed', $false, '✕')
            }
            'Created' {
                return [FleetCardStatus]::new([FleetCardState]::Queued, 'Queued',
                    'BodyTextTertiary', $false, '○')
            }
            'Running' {
                if ($jobType -eq 'UpdateApply') {
                    return [FleetCardStatus]::new([FleetCardState]::Updating, 'Updating…',
                        'AccentPurple', $true, '↻')
                }
                # Scan and UpdateScan are both "scanning" from the user's view.
                return [FleetCardStatus]::new(
                    [FleetCardState]::Scanning, 'Scanning…', 'AccentCyan', $true, '↻')
            }
            'Completed' {
                if ($rebootRequired) {
                    return [FleetCardStatus]::new([FleetCardState]::RebootRequired,
                        'Reboot required', 'AccentYellow', $false, '⚠')
                }
                return [FleetCardStatus]::new([FleetCardState]::Completed, 'Completed',
                    'AccentGreen', $false, '✓')
            }
        }

        # Unknown status: treat as queued so a card still renders something sane.
        return [FleetCardStatus]::new(
            [FleetCardState]::Queued, 'Queued', 'BodyTextTertiary', $false, '○')
    }

    # A still-Running job whose connection dropped and is reconnecting + resuming (applied by
    # the pump on reconnect lines). Amber (the 'Unconfirmed' tone) + busy so the bar pulses.
    static [FleetCardStatus] Reconnecting() {
        return [FleetCardStatus]::new(
            [FleetCardState]::Reconnecting, 'Reconnecting…', 'AccentOrange', $true, '↻')
    }
}
