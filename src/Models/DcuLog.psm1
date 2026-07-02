<#
.SYNOPSIS
    Pure parser for dcu-cli's activity log (the -outputLog file).

.DESCRIPTION
    dcu-cli writes a timestamped activity log to its -outputLog path, ending each
    run with a line like "[2026-07-02 15:15:43] : The program exited with return
    code: 0". That line is dcu-cli's AUTHORITATIVE result - unlike psexec's process
    exit code, which can be a transport artifact (e.g. 233 when applying a network
    driver resets the NIC and drops psexec's own pipe). When psexec reports a
    connection-lost code, the worker reads this log to recover what dcu-cli actually
    did.

.NOTES
    Pure + WPF-free + dependency-free, so it loads in a worker runspace and is
    unit-testable without a live host. Returns the LAST return-code line, so it is
    correct whether dcu-cli overwrote or appended the file (the worker also clears
    the log before each run, so in practice only this run's lines are present).
#>
class DcuLog {
    # Extracts dcu-cli's final return code from its activity-log text. Returns
    # @{ Found = $bool; Code = [int] } - Found is $false (Code 0) when no
    # "return code: N" line is present (e.g. dcu-cli never finished writing it).
    static [hashtable] ParseReturnCode([string]$logText) {
        if ([string]::IsNullOrWhiteSpace($logText)) { return @{ Found = $false; Code = 0 } }
        # dcu-cli: "The program exited with return code: 0". Tolerate case/spacing and
        # take the LAST occurrence (the most recent run's result).
        $matches = [regex]::Matches($logText, '(?im)return\s+code:\s*(-?\d+)')
        if ($matches.Count -eq 0) { return @{ Found = $false; Code = 0 } }
        $last = $matches[$matches.Count - 1]
        return @{ Found = $true; Code = [int]$last.Groups[1].Value }
    }
}
