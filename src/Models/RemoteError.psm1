<#
.SYNOPSIS
    Typed, severity-tagged exceptions for remote-operation failures.

.DESCRIPTION
    A small exception hierarchy so a failure's TYPE and MESSAGE state its cause
    instead of a generic string: RemoteOperationException is the base (it carries
    the HostName, a severity Level, and a coarse Reason), and each subclass names a
    specific cause (offline / unresolvable / RPC blocked). Callers can catch a
    specific type, surface the message, and log at the carried Level. WPF-free and
    dependency-free so it also loads in a worker runspace and is unit-testable.

    RemoteFailure re-derives the Reason from a worker error MESSAGE: the exception
    type is lost when an error crosses the runspace boundary (worker -> UI), but
    the message survives, so the UI maps the (stable, self-authored) message back
    to a Reason to pick a card state.

.NOTES
    An offline host is a Warning (it may simply be powered off); a DNS/AD
    resolution failure or a blocked RPC port is an Error (a real connectivity or
    configuration fault that needs attention).
#>

# Severity of a failure, aligned with the LogService levels.
enum ErrorLevel {
    Info
    Warning
    Error
}

# Coarse, machine-readable reason for a remote failure - drives the card state.
enum RemoteFailureReason {
    Offline
    Unresolvable
    RpcUnavailable
    Unknown
}

# Base for a remote-operation failure: WHAT failed (the concrete subclass), WHO it
# was about ($HostName), how severe it is ($Level), and a coarse $Reason token.
class RemoteOperationException : System.Exception {
    [string]              $HostName
    [ErrorLevel]          $Level
    [RemoteFailureReason] $Reason

    RemoteOperationException([string]$message, [string]$hostName, [ErrorLevel]$level, [RemoteFailureReason]$reason) : base($message) {
        $this.HostName = $hostName
        $this.Level = $level
        $this.Reason = $reason
    }
}

# The host did not answer a reachability check - usually just powered off.
class HostOfflineException : RemoteOperationException {
    HostOfflineException([string]$hostName) : base(
        "Host '$hostName' is offline or unreachable (no response to the reachability check).",
        $hostName, [ErrorLevel]::Warning, [RemoteFailureReason]::Offline) {}
}

# The host name could not be resolved to an IP (DNS / AD lookup failed).
class HostUnresolvableException : RemoteOperationException {
    HostUnresolvableException([string]$hostName) : base(
        "Could not resolve an IP for '$hostName' - the DNS/AD lookup failed. Check the name and that the host is in the directory.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::Unresolvable) {}
}

# The host is up but RPC (port 135, the transport PsExec/CIM use) is blocked.
class RpcUnavailableException : RemoteOperationException {
    RpcUnavailableException([string]$hostName) : base(
        "RPC (port 135) is not reachable on '$hostName'. Check the Windows Firewall and that the host has finished booting.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::RpcUnavailable) {}
}

# Re-derives the failure reason from a worker error message. Pure + WPF-free so the
# presenter can pick a card state without depending on the exception type surviving
# the runspace boundary. Matches the stable phrases the exceptions above emit.
class RemoteFailure {
    static [RemoteFailureReason] ReasonFromMessage([string]$message) {
        if ([string]::IsNullOrWhiteSpace($message)) { return [RemoteFailureReason]::Unknown }
        if ($message -match '(?i)offline or unreachable')            { return [RemoteFailureReason]::Offline }
        if ($message -match '(?i)could not resolve an ip|dns/ad')    { return [RemoteFailureReason]::Unresolvable }
        if ($message -match '(?i)rpc \(port 135\)')                  { return [RemoteFailureReason]::RpcUnavailable }
        return [RemoteFailureReason]::Unknown
    }
}
