# TimeFormat
#
# Pure helper for rendering "time ago" labels in the machine list (e.g. the
# subtitle "Completed · 2 min ago"). WPF-free so it can be unit-tested.

class TimeFormat {
    # Renders a coarse relative time for a past instant. Input may be UTC or
    # local Kind; it is normalised to UTC and compared against UtcNow.
    static [string] Relative([datetime]$when) {
        $whenUtc = if ($when.Kind -eq [System.DateTimeKind]::Utc) {
            $when
        } else {
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
