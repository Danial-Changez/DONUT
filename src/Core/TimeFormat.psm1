<#
.SYNOPSIS
    Pure helpers for time parsing and coarse "time ago" labels.

.DESCRIPTION
    Renders a relative time for a past instant (e.g. the machine-list subtitle
    "Completed · 2 min ago"). Input may be UTC or local Kind; it is normalised to
    UTC and compared against UtcNow. ParseIso turns a stored ISO8601 stamp into a
    sortable DateTime (blank/invalid -> MinValue). WPF-free so it can be unit-tested.
#>
class TimeFormat {
    # Parses a stored ISO8601 stamp into a sortable DateTime (blank/invalid -> MinValue).
    static [datetime] ParseIso([string]$value) {
        if ([string]::IsNullOrWhiteSpace($value)) { return [datetime]::MinValue }
        $parsed = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($value, [System.Globalization.CultureInfo]::InvariantCulture,
                $styles, [ref]$parsed)) {
            return $parsed
        }
        return [datetime]::MinValue
    }

    # ConvertFrom-Json sniffs ISO strings into [datetime]; a bare [string] cast then
    # drops the zone marker and the instant shifts by the machine's UTC offset.
    static [string] NormalizeStamp($value) {
        if ($value -is [System.DateTimeOffset]) { return $value.UtcDateTime.ToString('o') }
        if ($value -isnot [datetime]) { return [string]$value }
        # Stamp fields are UTC by contract, so an unzoned parse is taken as UTC.
        if ($value.Kind -eq [System.DateTimeKind]::Unspecified) {
            $value = [datetime]::SpecifyKind($value, [System.DateTimeKind]::Utc)
        }
        return $value.ToUniversalTime().ToString('o')
    }

    static [string] Relative([datetime]$when) {
        $whenUtc = if ($when.Kind -eq [System.DateTimeKind]::Utc) {
            $when
        }
        else {
            $when.ToUniversalTime()
        }

        $span = [datetime]::UtcNow - $whenUtc

        # Clamp tiny negative skew (clocks, rounding) to "just now".
        if ($span.TotalSeconds -lt 60) { return 'just now' }
        if ($span.TotalMinutes -lt 60) {
            $m = [int]$span.TotalMinutes
            return "$m min ago"
        }
        if ($span.TotalHours -lt 24) {
            $h = [int]$span.TotalHours
            return "$h hr ago"
        }
        if ($span.TotalHours -lt 48) { return 'yesterday' }
        if ($span.TotalDays -lt 7) {
            $d = [int]$span.TotalDays
            return "$d days ago"
        }

        # Older than a week: show a short absolute date (local).
        return $whenUtc.ToLocalTime().ToString('MMM d')
    }
}
