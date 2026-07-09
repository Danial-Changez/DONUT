<#
.SYNOPSIS
    Pure helper that pulls a progress percentage out of a dcu-cli output line.

.DESCRIPTION
    Dell Command Update streams transfer progress like:

        Downloading updates (1 of 3), 0 bytes of 1.5 GB transferred (0.00%)...
        Downloading updates (3 of 3), 185.1 MB of 1.5 GB transferred (12.26%)...

    The decimal separator is locale-dependent: comma-locale machines emit
    "(12,26%)" rather than "(12.26%)". Both are accepted and parsed
    culture-invariantly so the fleet card shows a real determinate bar during
    download/install instead of an indeterminate spinner.

.NOTES
    WPF-free so it can be unit-tested out of process.
#>
class DcuProgress {
    # Returns the percentage (0-100) found in a line, or -1 when the line carries
    # no progress figure. When several appear, the last one wins.
    static [double] ParsePercent([string]$line) {
        if ([string]::IsNullOrWhiteSpace($line)) { return -1 }

        # Decimal separator may be '.' or ',' depending on the remote's locale.
        $found = [regex]::Matches($line, '\(\s*([0-9]+(?:[.,][0-9]+)?)\s*%\s*\)')
        if ($found.Count -eq 0) { return -1 }

        $raw = $found[$found.Count - 1].Groups[1].Value -replace ',', '.'
        $value = [double]::Parse($raw, [System.Globalization.CultureInfo]::InvariantCulture)
        if ($value -lt 0) { return 0 }
        if ($value -gt 100) { return 100 }
        return $value
    }

    # --- Scan-phase steps ---

    # A dcu-cli scan emits no percentages but walks fixed milestone lines; mapping them
    # to step numbers gives a real "N/5" progression instead of an anonymous spinner.

    static [int] $ScanStepCount = 5

    # Maps a dcu-cli output line to its scan step (1-5; 0 = not a milestone). NOTE: the
    # more specific "application component updates" pattern must be tested first.
    static [int] ParseScanStep([string]$line) {
        if ([string]::IsNullOrWhiteSpace($line)) { return 0 }
        if ($line -match '(?i)checking for application component updates') { return 2 }
        if ($line -match '(?i)checking for updates') { return 1 }
        if ($line -match '(?i)scanning system devices') { return 3 }
        if ($line -match '(?i)determining available updates') { return 4 }
        if ($line -match '(?i)check for updates completed') { return 5 }
        return 0
    }

    # Short human label for a scan step (shown beside the bar as "2/5 label").
    static [string] ScanStepLabel([int]$step) {
        switch ($step) {
            1 { return 'checking for updates' }
            2 { return 'checking components' }
            3 { return 'scanning devices' }
            4 { return 'determining updates' }
            5 { return 'scan complete' }
        }
        return ''
    }

    # --- Reconnect / resume status lines ---

    # The worker prefixes reconnect/resume status lines with this token so the pump can turn
    # them into a "Reconnecting…" card (and strip it for display). ASCII with a leading '[r'
    # so it renders in any font and never collides with a dcu-cli line (those start "[<date>").
    static [string] $ReconnectMarker = '[reconnect] '

    # True when a tailed line is one of the worker's reconnect/resume status lines. It never
    # matches ParsePercent/ParseScanStep, so it can't disturb the determinate bar.
    static [bool] IsReconnectLine([string]$line) {
        if ([string]::IsNullOrEmpty($line)) { return $false }
        return $line.StartsWith([DcuProgress]::ReconnectMarker, [System.StringComparison]::Ordinal)
    }

    # The human message with the detection token removed (for the detail terminal).
    static [string] StripReconnectMarker([string]$line) {
        if ([DcuProgress]::IsReconnectLine($line)) {
            return $line.Substring([DcuProgress]::ReconnectMarker.Length)
        }
        return $line
    }
}
