<#
.SYNOPSIS
    One detail-pane terminal line: severity + normalized HH:mm:ss stamp + text.

.DESCRIPTION
    The typed unit every terminal line travels as, from AsyncJob's stream drain to
    the DetailPane log ListBox. DONUT-authored lines are stamped at creation;
    worker/dcu-tailed lines re-stamp dcu-cli's full "[yyyy-MM-dd HH:mm:ss]" prefix
    down to HH:mm:ss so the terminal shows one uniform dim stamp (full fidelity
    stays in Donut.log and the copied <host>.log). Severity renders as a color AND
    a text tag ([Error]/[Warn]) so color is never the only carrier of meaning.

.NOTES
    Pure + WPF-free: lines are immutable after creation (DisplayText/StampText are
    precomputed for converter-free XAML bindings), so no INPC is needed. A blank
    Text makes a separator line, which carries no stamp.
#>

enum LogSeverity {
    Info
    Warn
    Error
    Success
}

class LogLine {
    [LogSeverity] $Severity = [LogSeverity]::Info
    [string] $Stamp = ''         # 'HH:mm:ss' local, or '' for separator lines
    [string] $Text = ''
    [string] $StampText = ''     # display twin of Stamp: 'HH:mm:ss ' (or '')
    [string] $DisplayText = ''   # Tag + Text, precomputed for the XAML Run binding

    # dcu-cli outputLog prefix: "[2026-07-02 15:15:43] : message" (":" optional).
    hidden static [regex] $DcuStamp = [regex]::new(
        '^\[(\d{4}-\d{2}-\d{2})[ T](\d{2}:\d{2}:\d{2})(?:\.\d+)?\]\s*:?\s*(.*)$')

    # Text tag per severity. Info and Success carry none (color and content suffice).
    static [string] Tag([LogSeverity]$severity) {
        if ($severity -eq [LogSeverity]::Error) { return '[Error] ' }
        if ($severity -eq [LogSeverity]::Warn) { return '[Warn] ' }
        return ''
    }

    hidden static [LogLine] Build([LogSeverity]$severity, [string]$stamp, [string]$text) {
        $l = [LogLine]::new()
        $l.Severity = $severity
        $l.Text = if ($null -ne $text) { $text } else { '' }
        $l.Stamp = if ($l.Text) { $stamp } else { '' }
        $l.StampText = if ($l.Stamp) { "$($l.Stamp) " } else { '' }
        $l.DisplayText = ([LogLine]::Tag($severity)) + $l.Text
        return $l
    }

    # A DONUT-authored line: stamped now. Blank text makes an unstamped separator.
    static [LogLine] Donut([LogSeverity]$severity, [string]$text) {
        return [LogLine]::Build($severity, [datetime]::Now.ToString('HH:mm:ss'), $text)
    }

    # A worker line: a dcu-cli date-time prefix is re-stamped as HH:mm:ss (no double
    # stamp) and prefixless lines are stamped now. Classification only upgrades.
    static [LogLine] FromWorkerLine([string]$text, [LogSeverity]$streamSeverity) {
        # $ts/$sev, not $stamp/$severity: locals matching property names break assignment.
        $ts = [datetime]::Now.ToString('HH:mm:ss')
        $body = if ($null -ne $text) { $text } else { '' }
        $m = [LogLine]::DcuStamp.Match($body)
        if ($m.Success) {
            $ts = $m.Groups[2].Value
            $body = $m.Groups[3].Value
        }
        $sev = $streamSeverity
        # Advisory only: a matched word lifts Info to Warn, but the return code decides.
        if ($sev -eq [LogSeverity]::Info -and
            $body -match '(?i)\b(error|failed|failure|warning)\b') {
            $sev = [LogSeverity]::Warn
        }
        return [LogLine]::Build($sev, $ts, $body)
    }

    # Same stamp and severity, different text (a reconnect line with its marker stripped).
    [LogLine] WithText([string]$newText) {
        return [LogLine]::Build($this.Severity, $this.Stamp, $newText)
    }
}
