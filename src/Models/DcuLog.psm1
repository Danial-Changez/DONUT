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
        $hits = [regex]::Matches($logText, '(?im)return\s+code:\s*(-?\d+)')
        if ($hits.Count -eq 0) { return @{ Found = $false; Code = 0 } }
        $last = $hits[$hits.Count - 1]
        return @{ Found = $true; Code = [int]$last.Groups[1].Value }
    }

    # dcu-cli's documented return codes. Only 0 is success; 1 and 5 mean a reboot is
    # needed; EVERYTHING ELSE is an error (2/3/4 are NOT benign - a common trap, since
    # they're small numbers). Reference:
    # https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
    static [hashtable] $Meanings = @{
        0 = 'success'
        1 = 'reboot required'
        2 = 'unknown application error'
        3 = 'the system manufacturer is not Dell'
        4 = 'dcu-cli was not run with administrative privilege'
        5 = 'a reboot was pending from a previous operation'
        6 = 'another instance of Dell Command Update is already running'
        7 = 'the application does not support this system model'
        8 = 'no update filters are configured'
    }

    # The codes that are NOT failures: 0 (done) plus 1 and 5 (done, but reboot to finish).
    static [int[]] $SuccessCodes = @(0, 1, 5)
    static [int[]] $RebootCodes  = @(1, 5)

    static [bool] IsSuccess([int]$code) { return [DcuLog]::SuccessCodes -contains $code }
    static [bool] NeedsReboot([int]$code) { return [DcuLog]::RebootCodes -contains $code }

    # Human meaning for a return code, with a category hint for the documented ranges.
    static [string] DescribeReturnCode([int]$code) {
        if ([DcuLog]::Meanings.ContainsKey($code)) { return [DcuLog]::Meanings[$code] }
        $range = switch ($code) {
            { $_ -ge 100 -and $_ -le 113 }   { 'input-validation error'; break }
            { $_ -ge 500 -and $_ -le 503 }   { 'scan error'; break }
            { $_ -ge 1000 -and $_ -le 1002 } { 'apply-updates error'; break }
            { $_ -ge 1505 -and $_ -le 1506 } { 'configure error'; break }
            { $_ -ge 2000 -and $_ -le 2007 } { 'driver-install error'; break }
            default { 'error' }
        }
        return $range
    }
}
