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

    Return-code reference:
    https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
#>

# Per-command verdict: a scan's 500 is a clean no-updates result, not a failure.
enum DcuCommandOutcome {
    Success
    RebootRequired
    NoUpdates
    Failed
}

class DcuLog {
    # Extracts dcu-cli's final return code as Found plus Code. Found is $false when no
    # "return code: N" line is present, meaning dcu-cli never finished.
    static [hashtable] ParseReturnCode([string]$logText) {
        if ([string]::IsNullOrWhiteSpace($logText)) { return @{ Found = $false; Code = 0 } }
        # Case and spacing vary, and the last occurrence is the most recent run's result.
        $hits = [regex]::Matches($logText, '(?im)return\s+code:\s*(-?\d+)')
        if ($hits.Count -eq 0) { return @{ Found = $false; Code = 0 } }
        $last = $hits[$hits.Count - 1]
        return @{ Found = $true; Code = [int]$last.Groups[1].Value }
    }

    # 0/1/5 pass for any command, a scan's 500 is clean (see Classify), the rest are errors.
    static [hashtable] $Meanings = @{
        0    = 'success'
        1    = 'reboot required'
        2    = 'unknown application error'
        3    = 'the system manufacturer is not Dell'
        4    = 'dcu-cli was not run with administrative privilege'
        5    = 'a reboot was pending from a previous operation'
        6    = 'another instance of Dell Command Update is already running'
        7    = 'the application does not support this system model'
        8    = 'no update filters are configured'
        112  = 'an invalid catalog was provided'
        500  = 'no updates were found for the system'
        501  = 'an error occurred while determining the available updates'
        502  = 'the scan was canceled'
        503  = 'a download error occurred during the scan'
        1000 = 'an error occurred while retrieving the apply-updates result'
        1001 = 'the apply-updates operation was canceled'
        1002 = 'a download error occurred while applying updates'
        3000 = 'the Dell Client Management Service is not running - retry after the service settles'
        3001 = 'the Dell Client Management Service is not installed - install it from Dell support'
        3002 = 'the Dell Client Management Service is disabled - enable the service'
        3003 = 'the Dell Client Management Service is busy - retry after the service settles'
        3004 = 'the Dell Client Management Service is installing a self-update - retry after the service settles'
        3005 = 'the Dell Client Management Service is installing pending updates - retry after the service settles'
    }

    # The codes that are not failures: 0 (done) plus 1 and 5 (done, but reboot to finish).
    static [int[]] $SuccessCodes = @(0, 1, 5)
    static [int[]] $RebootCodes  = @(1, 5)
    # Scan-only: dcu-cli exits 500 when the scan ran clean and found nothing to install.
    static [int[]] $ScanNoUpdateCodes = @(500)

    static [bool] NeedsReboot([int]$code) { return [DcuLog]::RebootCodes -contains $code }

    # The per-command verdict InvokePsExec gates on. Only Failed should throw.
    static [DcuCommandOutcome] Classify([string]$command, [int]$code) {
        if ($command -eq 'scan' -and [DcuLog]::ScanNoUpdateCodes -contains $code) {
            return [DcuCommandOutcome]::NoUpdates
        }
        if ([DcuLog]::RebootCodes -contains $code) { return [DcuCommandOutcome]::RebootRequired }
        if ([DcuLog]::SuccessCodes -contains $code) { return [DcuCommandOutcome]::Success }
        return [DcuCommandOutcome]::Failed
    }

    # Human meaning for a return code, with a category hint for the documented ranges.
    static [string] DescribeReturnCode([int]$code) {
        if ([DcuLog]::Meanings.ContainsKey($code)) { return [DcuLog]::Meanings[$code] }
        $range = switch ($code) {
            { $_ -ge 100 -and $_ -le 113 } { 'input-validation error'; break }
            { $_ -ge 500 -and $_ -le 503 } { 'scan error'; break }
            { $_ -ge 1000 -and $_ -le 1002 } { 'apply-updates error'; break }
            { $_ -ge 1505 -and $_ -le 1506 } { 'configure error'; break }
            { $_ -ge 2000 -and $_ -le 2007 } { 'driver-install error'; break }
            { $_ -ge 2500 -and $_ -le 2502 } { 'password-encryption error'; break }
            { $_ -ge 3000 -and $_ -le 3005 } { 'Dell Client Management Service error'; break }
            default { 'error' }
        }
        return $range
    }
}
