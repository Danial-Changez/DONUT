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
enum FleetState {
    Queued
    Scanning
    Updating
    Completed
    RebootRequired
    Failed
}

class FleetStatus {
    [FleetState] $State
    [string]     $Label
    [string]     $ColorKey   # resource key into UIColors.xaml
    [bool]       $IsBusy     # true => indeterminate progress bar is animating

    FleetStatus([FleetState]$state, [string]$label, [string]$colorKey, [bool]$isBusy) {
        $this.State    = $state
        $this.Label    = $label
        $this.ColorKey = $colorKey
        $this.IsBusy   = $isBusy
    }

    # Maps a job's coordinates to a display status.
    #   jobType        - 'Scan' | 'UpdateScan' | 'UpdateApply'
    #   status         - 'Created' | 'Running' | 'Completed' | 'Failed'
    #   rebootRequired - host flagged for a manual reboot after applying updates
    static [FleetStatus] FromJob([string]$jobType, [string]$status, [bool]$rebootRequired) {
        switch ($status) {
            'Failed' {
                return [FleetStatus]::new([FleetState]::Failed, 'Failed', 'AccentRed', $false)
            }
            'Created' {
                return [FleetStatus]::new([FleetState]::Queued, 'Queued', 'BodyTextTertiary', $false)
            }
            'Running' {
                if ($jobType -eq 'UpdateApply') {
                    return [FleetStatus]::new([FleetState]::Updating, 'Updating…', 'AccentPurple', $true)
                }
                # Scan and UpdateScan are both "scanning" from the user's view.
                return [FleetStatus]::new([FleetState]::Scanning, 'Scanning…', 'AccentCyan', $true)
            }
            'Completed' {
                if ($rebootRequired) {
                    return [FleetStatus]::new([FleetState]::RebootRequired, 'Reboot required', 'AccentYellow', $false)
                }
                return [FleetStatus]::new([FleetState]::Completed, 'Completed', 'AccentGreen', $false)
            }
        }

        # Unknown status: treat as queued so a card still renders something sane.
        return [FleetStatus]::new([FleetState]::Queued, 'Queued', 'BodyTextTertiary', $false)
    }
}
