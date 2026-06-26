# DcuProgress
#
# Pure helper that pulls a progress percentage out of a Dell Command Update
# (dcu-cli) output line. DCU streams transfer progress like:
#
#   Downloading updates (1 of 3), 0 bytes of 1.5 GB transferred (0.00%)...
#   Downloading updates (3 of 3), 185.1 MB of 1.5 GB transferred (12.26%)...
#
# The decimal separator is locale-dependent: machines in comma-locales emit
# "(12,26%)" rather than "(12.26%)". We accept either and parse the number
# culture-invariantly so the fleet card shows a real determinate bar during
# download/install instead of an indeterminate spinner.
#
# WPF-free so it can be unit-tested out of process.

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
}
