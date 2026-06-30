<#
.SYNOPSIS
    Pure mapper from a device-flow poll result to the login loop's next action.

.DESCRIPTION
    Translates a SelfUpdateService.PollForToken result into the next step the
    GitHub device-flow login loop should take (authorize / keep polling / slow
    down / fail). WPF-free so the polling decision can be unit-tested without a
    window or timer; LoginPresenter applies the decision to the real UI/timer.
    Mirrors the FleetStatus / DcuProgress pure-mapper pattern.
#>
enum PollOutcome {
    Authorized    # token received: save it and finish
    KeepPolling   # authorization_pending (or a transient hiccup): poll again
    SlowDown      # GitHub asked us to back off: lengthen the interval
    Failed        # terminal error (expired/denied/etc.): stop and report
}

class DeviceFlowDecision {
    [PollOutcome] $Outcome
    [object]      $TokenData   # set when Outcome = Authorized
    [string]      $Message     # set when Outcome = Failed (user-facing text)

    DeviceFlowDecision([PollOutcome]$outcome) {
        $this.Outcome = $outcome
    }

    # Maps a PollForToken result (a PSCustomObject with a Status field) to the
    # next poll-loop action. A $null result is treated as "keep polling" (a
    # transient network hiccup), matching the service's retry intent.
    static [DeviceFlowDecision] FromPollResult([object]$result) {
        if ($null -eq $result) {
            return [DeviceFlowDecision]::new([PollOutcome]::KeepPolling)
        }

        switch ([string]$result.Status) {
            'authorized' {
                $d = [DeviceFlowDecision]::new([PollOutcome]::Authorized)
                $d.TokenData = $result.TokenData
                return $d
            }
            'pending'   { return [DeviceFlowDecision]::new([PollOutcome]::KeepPolling) }
            'slow_down' { return [DeviceFlowDecision]::new([PollOutcome]::SlowDown) }
            default {
                $d = [DeviceFlowDecision]::new([PollOutcome]::Failed)
                $d.Message = "Error: $($result.Error)"
                return $d
            }
        }

        # Unreachable: the switch above returns for every status (default covers
        # the rest). Present so every code path provably returns.
        return [DeviceFlowDecision]::new([PollOutcome]::KeepPolling)
    }
}
