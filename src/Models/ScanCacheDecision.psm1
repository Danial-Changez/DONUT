# ScanCacheDecision
#
# Pure mapper deciding whether a host's most recent scan can be REUSED instead of
# re-scanning. WPF-free so the "is the cached scan still good?" rule is unit-tested
# without a presenter/store; HomePresenter feeds it the recents fields + whether the
# report file still exists. Mirrors the DeviceFlowDecision/FleetStatus pure-mapper
# pattern.
#
# Reuse is allowed only when the host's LAST completed job was a Scan/UpdateScan (a
# successful apply records 'UpdateApply', so reuse is off afterwards -> the next run
# re-scans), it ran within the TTL, and its update report is still on disk.

class ScanCacheDecision {
    static [bool] IsFresh([string]$lastJobType, [datetime]$lastSeen, [datetime]$now, [timespan]$ttl, [bool]$reportExists) {
        if ($lastJobType -ne 'Scan' -and $lastJobType -ne 'UpdateScan') { return $false }
        if ($lastSeen -eq [datetime]::MinValue) { return $false }
        if (($now - $lastSeen) -gt $ttl) { return $false }
        return $reportExists
    }
}
