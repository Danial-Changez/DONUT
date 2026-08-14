<#
.SYNOPSIS
    Slim, class-free worker for one background IP resolve (the fast lane).

.DESCRIPTION
    Spawned DIRECTLY by ResolveProcessJob - no runspace pool slot, no worker
    module graph. Resolves the host's A record against the active DC
    (authoritative, the NetworkProbe.ResolveViaServer semantics) and probes TCP
    135 with a 2 s cap, then writes the @{ Mode='Host'; HostName; Ip; Online }
    verdict JSON to -ResultFile - byte-compatible with what CompleteResolve
    consumes from the classic path.

    A DNS no-answer is a VERDICT (Ip = '', exit 0). Only infrastructure faults
    exit non-zero with no result file - the parent flags ProcessFault and falls
    back to the classic worker path.

.NOTES
    Keep this class-free: its whole point is skipping the ~12-module worker
    graph compile (LogService is the one allowed import; it imports nothing).
    Dot-source with no -ResultFile to load the functions for tests without
    running the resolve.
#>
using module "..\Core\LogService.psm1"

param(
    [string]$HostName,
    [string]$Dc,
    [string]$LogsDir,
    [string]$ResultFile,
    # Parent's effective debug-log state, since this worker's lines are all [DEBUG].
    [switch]$DebugLog
)

$ErrorActionPreference = 'Stop'

# NetworkProbe.ResolveWith semantics: authoritative A lookup against the DC. Returns
# '' on any failure, which is a verdict rather than an error, since the host may not exist.
function Resolve-TargetIp {
    param([string]$TargetHost, [string]$Server, [object]$Log)
    if ([string]::IsNullOrWhiteSpace($Server)) {
        $Log.LogError("[$TargetHost] fast resolve: no domain controller supplied.")
        return ''
    }
    try {
        $Log.LogDebug("[$TargetHost] fast resolve: DNS via DC '$Server'...")
        $records = Resolve-DnsName -Name $TargetHost -Server $Server -Type A -ErrorAction Stop
        $a = $records | Where-Object { $_.IPAddress } | Select-Object -First 1
        if ($null -ne $a) { return [string]$a.IPAddress }
        return ''
    }
    catch {
        $Log.LogDebug("[$TargetHost] fast resolve: DNS via '$Server' failed: $($_.Exception.Message)")
        return ''
    }
}

# NetworkProbe.IsPortOpen port for RPC 135: bounded 2 s TCP connect. The breadcrumb
# logs before the connect, because a security-stack-hooked connect never returns.
function Test-RpcPort {
    param([string]$Ip, [object]$Log, [int]$Port = 135)
    try {
        $Log.LogDebug("[$Ip] fast resolve: RPC probe connecting to port $Port (2 s cap)...")
        $client = [System.Net.Sockets.TcpClient]::new()
        try { return $client.ConnectAsync($Ip, $Port).Wait(2000) }
        finally { $client.Close() }
    }
    catch {
        $Log.LogDebug("[$Ip] fast resolve: RPC probe failed: $($_.Exception.Message)")
        return $false
    }
}

# Dot-sourced by tests with no -ResultFile: functions defined, nothing runs.
if ([string]::IsNullOrWhiteSpace($ResultFile)) { return }

try {
    $log = if (-not [string]::IsNullOrWhiteSpace($LogsDir)) { [LogService]::new($LogsDir) }
    else { [NullLogService]::new() }
    $log.DebugEnabled = [bool]$DebugLog
    $log.LogDebug("[$HostName] Fast resolve up: DC='$Dc'.")

    $ip = Resolve-TargetIp -TargetHost $HostName -Server $Dc -Log $log
    $online = $false
    if (-not [string]::IsNullOrWhiteSpace($ip)) { $online = Test-RpcPort -Ip $ip -Log $log }
    $log.LogDebug("[$HostName] Fast resolve verdict: ip='$ip', online=$online.")

    @{ Mode = 'Host'; HostName = $HostName; Ip = $ip; Online = $online } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
}
catch {
    # No result file means an infrastructure fault, so the parent flags ProcessFault.
    [Console]::Error.WriteLine("Fast resolve failed: $($_.Exception.Message)")
    exit 1
}
