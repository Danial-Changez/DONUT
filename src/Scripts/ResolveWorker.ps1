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

    -Domain is the picked row's home AD domain, when the caller knows it: the
    lookup then asks for "<host>.<domain>" first, so a sibling-forest machine
    resolves in its own zone instead of riding this box's DNS suffix list (which
    either fails or, on a name collision, answers with the home forest's twin).
    The bare name stays as the fallback, and is all a domain-less caller gets.

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
    # The host's home AD domain when the pick knew it, else '' (see DESCRIPTION).
    [string]$Domain = '',
    [string]$LogsDir,
    [string]$ResultFile,
    # Parent's effective debug-log state, since this worker's lines are all [DEBUG].
    [switch]$DebugLog
)

$ErrorActionPreference = 'Stop'

# NetworkProbe.ResolveWith semantics: authoritative A lookup against the DC. Returns
# '' on any failure, which is a verdict rather than an error, since the host may not exist.
function Resolve-TargetIp {
    param([string]$TargetHost, [string]$Server, [object]$Log, [string]$Domain = '')
    if ([string]::IsNullOrWhiteSpace($Server)) {
        $Log.LogError("[$TargetHost] fast resolve: no domain controller supplied.")
        return ''
    }
    # The FQDN goes first when the home domain is known, and the bare name is the fallback.
    $names = @()
    if ($Domain -and $TargetHost -notmatch '\.') { $names += "$TargetHost.$Domain" }
    $names += $TargetHost
    foreach ($name in $names) {
        try {
            $Log.LogDebug("[$TargetHost] fast resolve: DNS '$name' via DC '$Server'...")
            $records = Resolve-DnsName -Name $name `
                                       -Server $Server `
                                       -Type A `
                                       -ErrorAction Stop
            $a = $records | Where-Object { $_.IPAddress } | Select-Object -First 1
            if ($null -ne $a) { return [string]$a.IPAddress }
        } catch {
            $Log.LogDebug("[$TargetHost] fast resolve: DNS '$name' via '$Server' failed: $($_.Exception.Message)")
        }
    }
    return ''
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
    } catch {
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
    $log.LogDebug("[$HostName] Fast resolve up: DC='$Dc', domain='$Domain'.")

    $ip = Resolve-TargetIp -TargetHost $HostName `
                           -Server $Dc `
                           -Log $log `
                           -Domain $Domain
    $online = $false
    if (-not [string]::IsNullOrWhiteSpace($ip)) { $online = Test-RpcPort -Ip $ip -Log $log }
    $log.LogDebug("[$HostName] Fast resolve verdict: ip='$ip', online=$online.")

    @{ Mode = 'Host'; HostName = $HostName; Ip = $ip; Online = $online } |
        ConvertTo-Json -Compress | Set-Content -LiteralPath $ResultFile -Encoding UTF8
} catch {
    # No result file means an infrastructure fault, so the parent flags ProcessFault.
    [Console]::Error.WriteLine("Fast resolve failed: $($_.Exception.Message)")
    exit 1
}
