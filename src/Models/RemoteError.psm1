<#
.SYNOPSIS
    Typed, severity-tagged exceptions for remote-operation failures.

.DESCRIPTION
    A small exception hierarchy so a failure's TYPE and MESSAGE state its cause
    instead of a generic string: RemoteOperationException is the base (it carries
    the HostName and a severity Level), and each subclass names a specific cause
    (offline / unresolvable / RPC blocked). Callers can catch a specific type,
    surface the message, and log at the carried Level. WPF-free and
    dependency-free so it also loads in a worker runspace and is unit-testable.

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

# Base for a remote-operation failure: WHAT failed (the concrete subclass), WHO it
# was about ($HostName), and how severe it is ($Level).
class RemoteOperationException : System.Exception {
    [string]     $HostName
    [ErrorLevel] $Level

    RemoteOperationException([string]$message, [string]$hostName, [ErrorLevel]$level) : base($message) {
        $this.HostName = $hostName
        $this.Level = $level
    }
}

# The host did not answer a reachability check - usually just powered off.
class HostOfflineException : RemoteOperationException {
    HostOfflineException([string]$hostName) : base(
        "Host '$hostName' is offline or unreachable (no response to the reachability check).",
        $hostName, [ErrorLevel]::Warning) {}
}

# The host name could not be resolved to an IP (DNS / AD lookup failed).
class HostUnresolvableException : RemoteOperationException {
    HostUnresolvableException([string]$hostName) : base(
        "Could not resolve an IP for '$hostName' - the DNS/AD lookup failed. Check the name and that the host is in the directory.",
        $hostName, [ErrorLevel]::Error) {}
}

# The host is up but RPC (port 135, the transport PsExec/CIM use) is blocked.
class RpcUnavailableException : RemoteOperationException {
    RpcUnavailableException([string]$hostName) : base(
        "RPC (port 135) is not reachable on '$hostName'. Check the Windows Firewall and that the host has finished booting.",
        $hostName, [ErrorLevel]::Error) {}
}
