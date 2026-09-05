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

    The transport codes in RemoteConnectionLostException.Codes do not overlap dcu-cli's
    return-code ranges, so any of them means the transport died rather than the command
    failing. Codes in the 5x, 59 and 123x groups mean the local side dropped.
#>

# Severity of a failure, aligned with the LogService levels.
enum ErrorLevel {
    Info
    Warning
    Error
}

# Coarse, machine-readable reason for a remote failure, which drives the card state.
enum RemoteFailureReason {
    Offline
    Unresolvable
    RpcUnavailable
    ExecutionFailed
    DcuMissing
    UnsupportedMake
    ProcessStartFailed
    ConnectionLost
    TimedOut
    Unknown
}

# Base for a remote-operation failure: what failed (the concrete subclass), who it
# was about ($HostName), how severe it is ($Level), and a coarse $Reason token.
class RemoteOperationException : System.Exception {
    [string]              $HostName
    [ErrorLevel]          $Level
    [RemoteFailureReason] $Reason

    RemoteOperationException([string]$message, [string]$hostName,
        [ErrorLevel]$level, [RemoteFailureReason]$reason) : base($message) {
        $this.HostName = $hostName
        $this.Level = $level
        $this.Reason = $reason
    }
}

# The host did not answer a reachability check, usually just powered off.
class HostOfflineException : RemoteOperationException {
    HostOfflineException([string]$hostName) : base(
        "Host '$hostName' is offline or unreachable (no response to the reachability check).",
        $hostName, [ErrorLevel]::Warning, [RemoteFailureReason]::Offline) {}
}

# The host name could not be resolved to an IP (DNS / AD lookup failed).
class HostUnresolvableException : RemoteOperationException {
    HostUnresolvableException([string]$hostName) : base(
        "Could not resolve an IP for '$hostName' - the DNS/AD lookup failed. " +
        "Check the name and that the host is in the directory.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::Unresolvable) {}
}

# The host is up but RPC (port 135, the transport PsExec/CIM use) is blocked.
class RpcUnavailableException : RemoteOperationException {
    RpcUnavailableException([string]$hostName) : base(
        "RPC (port 135) is not reachable on '$hostName'. " +
        "Check the Windows Firewall and that the host has finished booting.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::RpcUnavailable) {}
}

# A remote command (PsExec -> dcu-cli or a probe) ran but exited non-zero.
class RemoteExecutionException : RemoteOperationException {
    [int] $ExitCode

    # Decodes the Win32 transport codes operators actually hit (psexec surfaces them as
    # its exit code). Anything else keeps the bare-number form.
    RemoteExecutionException([string]$hostName, [string]$what, [int]$exitCode) : base(
        $(switch ($exitCode) {
                5 {
                    "$what failed on '$hostName' (exit code 5 - access denied: " +
                    "the account DONUT runs as is not an admin on the target)."
                }
                53 { "$what failed on '$hostName' (exit code 53 - the network path to the target was not found)." }
                1219 {
                    "$what failed on '$hostName' (exit code 1219 - " +
                    "an existing connection to the target uses different credentials)."
                }
                1326 { "$what failed on '$hostName' (exit code 1326 - the user name or password is incorrect)." }
                default { "$what failed on '$hostName' (exit code $exitCode)." }
            }),
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::ExecutionFailed) {
        $this.ExitCode = $exitCode
    }

    # Same, but with the decoded meaning appended, so a DCU error code reads as its cause.
    RemoteExecutionException([string]$hostName, [string]$what,
        [int]$exitCode, [string]$detail) : base(
        $(if ([string]::IsNullOrWhiteSpace($detail)) { "$what failed on '$hostName' (exit code $exitCode)." }
            else { "$what failed on '$hostName' (exit code $exitCode - $detail)." }),
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::ExecutionFailed) {
        $this.ExitCode = $exitCode
    }
}

# The remote process (pwsh) failed to start or crashed during startup: an NTSTATUS
# fault (e.g. 0xC0000142), not a dcu-cli exit code, and often transient.
class RemoteProcessStartException : RemoteOperationException {
    [int] $ExitCode

    RemoteProcessStartException([string]$hostName, [string]$what, [int]$exitCode) : base(
        "$what could not run on '$hostName': the remote process exited during startup " +
        "($([RemoteProcessStartException]::Describe($exitCode))). " +
        "This is a Windows process-launch failure, not a DCU error - commonly session-0 " +
        "desktop-heap exhaustion after repeated remote runs, or AV/EDR interference; " +
        "it often succeeds on retry.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::ProcessStartFailed) {
        $this.ExitCode = $exitCode
    }

    # Formats a process exit code as its unsigned NTSTATUS hex plus a known name when we
    # have one (so "-1073741502" reads as "0xC0000142 STATUS_DLL_INIT_FAILED").
    static [string] Describe([int]$exitCode) {
        $hex = '0x{0:X8}' -f ([int64]$exitCode -band 0xFFFFFFFFL)
        $known = @{
            '0xC0000142' = 'STATUS_DLL_INIT_FAILED'
            '0xC0000005' = 'STATUS_ACCESS_VIOLATION'
            '0xC000012D' = 'STATUS_COMMITMENT_LIMIT'
            '0xC0000017' = 'STATUS_NO_MEMORY'
        }
        if ($known.ContainsKey($hex)) { return "$hex $($known[$hex])" }
        return "exit code $exitCode / $hex"
    }
}

# psexec's connection dropped mid-command: a Win32 transport error (233, 64, ...), not
# a dcu-cli code. Either end can drop: the target's NIC reset or the operator's Wi-Fi.
class RemoteConnectionLostException : RemoteOperationException {
    [int] $ExitCode

    RemoteConnectionLostException([string]$hostName, [string]$what, [int]$exitCode) : base(
        "$what on '$hostName' could not be confirmed: psexec lost its connection to the host " +
        "($([RemoteConnectionLostException]::Describe($exitCode))). " +
        "This is a network/transport drop, not a DCU error - it typically happens when the " +
        "update resets the network (e.g. a NIC/Ethernet driver), which severs psexec's own " +
        "connection while dcu-cli finishes on the host. The update most likely applied; " +
        "re-scan to confirm.",
        $hostName, [ErrorLevel]::Warning, [RemoteFailureReason]::ConnectionLost) {
        $this.ExitCode = $exitCode
    }

    # None overlap dcu-cli's ranges, so any of these means the transport died. See .NOTES.
    static [hashtable] $Codes = @{
        51   = 'ERROR_REM_NOT_LIST'
        53   = 'ERROR_BAD_NETPATH'
        54   = 'ERROR_NETWORK_BUSY'
        55   = 'ERROR_DEV_NOT_EXIST'
        58   = 'ERROR_BAD_NET_RESP'
        59   = 'ERROR_UNEXP_NET_ERR'
        64   = 'ERROR_NETNAME_DELETED'
        109  = 'ERROR_BROKEN_PIPE'
        121  = 'ERROR_SEM_TIMEOUT'
        232  = 'ERROR_NO_DATA'
        233  = 'ERROR_PIPE_NOT_CONNECTED'
        1231 = 'ERROR_NETWORK_UNREACHABLE'
        1232 = 'ERROR_HOST_UNREACHABLE'
        1236 = 'ERROR_CONNECTION_ABORTED'
    }

    static [bool] IsConnectionLost([int]$exitCode) {
        return [RemoteConnectionLostException]::Codes.ContainsKey($exitCode)
    }

    # Formats a transport code with its Win32 name ("233" -> "code 233 ERROR_PIPE_NOT_CONNECTED").
    static [string] Describe([int]$exitCode) {
        $name = [RemoteConnectionLostException]::Codes[$exitCode]
        if ($name) { return "code $exitCode $name" }
        return "code $exitCode"
    }
}

# The operation ran past its watchdog and the local psexec client was killed so the worker
# could be reclaimed. The remote process may still be running.
class RemoteTimeoutException : RemoteOperationException {
    [int] $TimeoutMinutes

    RemoteTimeoutException([string]$hostName, [string]$what, [int]$timeoutMinutes) : base(
        "$what on '$hostName' did not finish within $timeoutMinutes minutes - " +
        "the psexec session was terminated. The remote process may still be running on the host; " +
        "give it a moment to settle before retrying.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::TimedOut) {
        $this.TimeoutMinutes = $timeoutMinutes
    }
}

# Dell Command Update is not installed on the target, so there is nothing to drive.
class DcuNotInstalledException : RemoteOperationException {
    DcuNotInstalledException([string]$hostName) : base(
        "Dell Command Update (dcu-cli.exe) is not installed on '$hostName'. Install DCU on the target machine.",
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::DcuMissing) {}
}

# The target is not a Dell, so there is no dcu-cli to drive: scans and updates cannot run.
class UnsupportedMakeException : RemoteOperationException {
    [string] $Manufacturer

    UnsupportedMakeException([string]$hostName, [string]$manufacturer) : base(
        "'$hostName' is $manufacturer hardware. DONUT drives Dell Command Update (dcu-cli), " +
        'so only Dell models are supported for scans and updates.',
        $hostName, [ErrorLevel]::Error, [RemoteFailureReason]::UnsupportedMake) {
        $this.Manufacturer = $manufacturer
    }
}

# Re-derives the failure reason from a worker error message, since the exception type does
# not survive the runspace boundary. Matches the stable phrases the exceptions above emit.
class RemoteFailure {
    static [RemoteFailureReason] ReasonFromMessage([string]$message) {
        if ([string]::IsNullOrWhiteSpace($message)) { return [RemoteFailureReason]::Unknown }
        if ($message -match '(?i)offline or unreachable') { return [RemoteFailureReason]::Offline }
        if ($message -match '(?i)could not resolve an ip|dns/ad') {
            return [RemoteFailureReason]::Unresolvable
        }
        if ($message -match '(?i)rpc \(port 135\)') { return [RemoteFailureReason]::RpcUnavailable }
        if ($message -match '(?i)is not installed on') { return [RemoteFailureReason]::DcuMissing }
        if ($message -match '(?i)only dell models are supported') {
            return [RemoteFailureReason]::UnsupportedMake
        }
        if ($message -match '(?i)process-launch failure|exited during startup') {
            return [RemoteFailureReason]::ProcessStartFailed
        }
        if ($message -match '(?i)lost its connection to the host') {
            return [RemoteFailureReason]::ConnectionLost
        }
        if ($message -match '(?i)did not finish within') { return [RemoteFailureReason]::TimedOut }
        if ($message -match '(?i)\(exit code') { return [RemoteFailureReason]::ExecutionFailed }
        return [RemoteFailureReason]::Unknown
    }
}
