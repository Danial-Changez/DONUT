<#
.SYNOPSIS
    Decides whether typed search text looks like a machine name.

.DESCRIPTION
    The Home search bar is dual-use (add a machine vs. find a person). This classifier
    answers "does this look like a machine name?" from a config-editable list of regex
    patterns (AppConfig.machineNamePatterns), so the dropdown can pre-select the
    "Add as a machine" action for a WSID and a person otherwise. Purely a hint - the
    operator can always pick the other row; nothing here decides what can be added.

.NOTES
    WPF-free so it can be unit-tested headless. Patterns are matched case-insensitively;
    a malformed pattern is skipped rather than breaking classification.
#>
class MachineNameMatcher {
    # Org defaults, mirrored in AppConfig.Defaults.machineNamePatterns (keep in sync).
    static [string[]] $DefaultPatterns = @('^CAP-', '^B[-0-9]', '^WVD')

    # True when the text is a single token matching any machine-name pattern. A blank
    # value, or text with whitespace (usually a "First Last" person search), is not a match.
    static [bool] LooksLikeMachine([string]$text, [string[]]$patterns) {
        if ([string]::IsNullOrWhiteSpace($text)) { return $false }
        $t = $text.Trim()
        if ($t -match '\s') { return $false }
        $pats = if ($null -eq $patterns -or $patterns.Count -eq 0) { [MachineNameMatcher]::DefaultPatterns } else { $patterns }
        foreach ($p in $pats) {
            if ([string]::IsNullOrWhiteSpace($p)) { continue }
            try {
                if ([System.Text.RegularExpressions.Regex]::IsMatch($t, $p, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
                    return $true
                }
            }
            catch { continue }
        }
        return $false
    }
}
