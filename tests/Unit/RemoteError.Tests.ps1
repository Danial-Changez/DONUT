using module "..\..\src\Models\RemoteError.psm1"

Describe "RemoteError" {
    Context "Exceptions carry type, level, and reason" {
        It "HostOfflineException is a Warning with the Offline reason" {
            $ex = [HostOfflineException]::new('PC-1')
            $ex.GetType().Name                  | Should -Be 'HostOfflineException'
            [string]$ex.Level                   | Should -Be 'Warning'
            [string]$ex.Reason                  | Should -Be 'Offline'
            $ex.HostName                        | Should -Be 'PC-1'
            ($ex -is [RemoteOperationException]) | Should -BeTrue
        }
        It "HostUnresolvableException is an Error with the Unresolvable reason" {
            $ex = [HostUnresolvableException]::new('PC-2')
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'Unresolvable'
        }
        It "RpcUnavailableException is an Error with the RpcUnavailable reason" {
            $ex = [RpcUnavailableException]::new('PC-3')
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'RpcUnavailable'
        }
        It "RemoteExecutionException carries the exit code (ExecutionFailed)" {
            $ex = [RemoteExecutionException]::new('PC-4', 'DCU /scan', 501)
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'ExecutionFailed'
            $ex.ExitCode       | Should -Be 501
            $ex.Message        | Should -BeLike '*exit code 501*'
        }
        # psexec returns Win32 codes, and 5 is the SYSTEM instance's not-admin-on-target signature.
        It "RemoteExecutionException decodes access denied (exit 5) into the message" {
            $ex = [RemoteExecutionException]::new('PC-4', 'Remote probe', 5)
            $ex.ExitCode | Should -Be 5
            $ex.Message  | Should -BeLike '*access denied*not an admin on the target*'
        }
        It "RemoteExecutionException appends a decoded detail when given one" {
            $ex = [RemoteExecutionException]::new('PC-4', 'DCU /scan', 3, 'the system manufacturer is not Dell')
            $ex.ExitCode | Should -Be 3
            $ex.Message  | Should -BeLike '*exit code 3 - the system manufacturer is not Dell*'
            [string][RemoteFailure]::ReasonFromMessage($ex.Message) | Should -Be 'ExecutionFailed'
        }
        It "RemoteExecutionException 4-arg tolerates a blank detail (no dangling dash)" {
            $ex = [RemoteExecutionException]::new('PC-4', 'DCU /scan', 3, '')
            $ex.Message | Should -BeLike '*exit code 3).*'
            $ex.Message | Should -Not -BeLike '*- ).*'
        }
        It "DcuNotInstalledException is an Error with the DcuMissing reason" {
            $ex = [DcuNotInstalledException]::new('PC-5')
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'DcuMissing'
        }
        It "UnsupportedMakeException carries the manufacturer and names the Dell-only reason" {
            $ex = [UnsupportedMakeException]::new('PC-9', 'LENOVO')
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'UnsupportedMake'
            $ex.Manufacturer   | Should -Be 'LENOVO'
            $ex.Message        | Should -BeLike '*LENOVO*'
            $ex.Message        | Should -BeLike '*only Dell models are supported*'
        }
        It "RemoteProcessStartException decodes an NTSTATUS exit code (ProcessStartFailed)" {
            $ex = [RemoteProcessStartException]::new('PC-6', 'DCU /applyUpdates', -1073741502)
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'ProcessStartFailed'
            $ex.ExitCode       | Should -Be -1073741502
            $ex.Message        | Should -BeLike '*0xC0000142 STATUS_DLL_INIT_FAILED*'
            $ex.Message        | Should -BeLike '*not a DCU error*'
        }
        It "RemoteProcessStartException.Describe names known NTSTATUS codes, hex-formats others" {
            [RemoteProcessStartException]::Describe(-1073741502) | Should -Be '0xC0000142 STATUS_DLL_INIT_FAILED'
            [RemoteProcessStartException]::Describe(-1073741819) | Should -Be '0xC0000005 STATUS_ACCESS_VIOLATION'
            [RemoteProcessStartException]::Describe(-559038737)  | Should -BeLike '*0xDEADBEEF*'
        }
        It "RemoteConnectionLostException is a Warning naming the transport code (ConnectionLost)" {
            $ex = [RemoteConnectionLostException]::new('PC-7', 'DCU /applyUpdates', 233)
            [string]$ex.Level  | Should -Be 'Warning'
            [string]$ex.Reason | Should -Be 'ConnectionLost'
            $ex.ExitCode       | Should -Be 233
            $ex.Message        | Should -BeLike '*233 ERROR_PIPE_NOT_CONNECTED*'
            $ex.Message        | Should -BeLike '*not a DCU error*'
            $ex.Message        | Should -BeLike '*re-scan to confirm*'
        }
        It "IsConnectionLost matches transport codes but never dcu-cli's own codes" {
            [RemoteConnectionLostException]::IsConnectionLost(233)  | Should -BeTrue   # ERROR_PIPE_NOT_CONNECTED
            [RemoteConnectionLostException]::IsConnectionLost(64)   | Should -BeTrue   # ERROR_NETNAME_DELETED
            [RemoteConnectionLostException]::IsConnectionLost(1236) | Should -BeTrue   # ERROR_CONNECTION_ABORTED
            foreach ($dcu in 0, 1, 2, 3, 4, 5, 105, 500, 1000) {
                [RemoteConnectionLostException]::IsConnectionLost($dcu) | Should -BeFalse
            }
        }
        It "IsConnectionLost also matches the LOCAL-side (client Wi-Fi drop) network codes" {
            # A client-side drop mid-run must recover, not hard-fail. None of these are dcu codes.
            foreach ($net in 51, 53, 54, 55, 58, 59, 1231, 1232) {
                [RemoteConnectionLostException]::IsConnectionLost($net) | Should -BeTrue
            }
        }
        It "RemoteConnectionLostException.Describe names known codes, bare-formats others" {
            [RemoteConnectionLostException]::Describe(64)  | Should -Be 'code 64 ERROR_NETNAME_DELETED'
            [RemoteConnectionLostException]::Describe(999) | Should -Be 'code 999'
        }
        It "RemoteTimeoutException is an Error carrying the watchdog limit (TimedOut)" {
            $ex = [RemoteTimeoutException]::new('PC-8', 'Remote probe', 20)
            [string]$ex.Level   | Should -Be 'Error'
            [string]$ex.Reason  | Should -Be 'TimedOut'
            $ex.TimeoutMinutes  | Should -Be 20
            $ex.Message         | Should -BeLike '*did not finish within 20 minutes*'
            $ex.Message         | Should -BeLike '*may still be running*'
        }
    }

    Context "RemoteFailure.ReasonFromMessage (re-derives reason across the runspace boundary)" {
        It "maps each exception's own message back to its reason" {
            $cases = @(
                @{ Ex = [HostOfflineException]::new('h'); Reason = 'Offline' }
                @{ Ex = [HostUnresolvableException]::new('h'); Reason = 'Unresolvable' }
                @{ Ex = [RpcUnavailableException]::new('h'); Reason = 'RpcUnavailable' }
                @{ Ex = [RemoteExecutionException]::new('h', 'DCU /scan', 500); Reason = 'ExecutionFailed' }
                @{ Ex = [DcuNotInstalledException]::new('h'); Reason = 'DcuMissing' }
                @{ Ex = [UnsupportedMakeException]::new('h', 'LENOVO'); Reason = 'UnsupportedMake' }
                @{ Ex      = [RemoteProcessStartException]::new('h', 'DCU /applyUpdates', -1073741502)
                    Reason = 'ProcessStartFailed'
                }
                @{ Ex = [RemoteConnectionLostException]::new('h', 'DCU /applyUpdates', 233); Reason = 'ConnectionLost' }
                @{ Ex = [RemoteTimeoutException]::new('h', 'Remote probe', 20); Reason = 'TimedOut' }
            )
            foreach ($c in $cases) {
                [string][RemoteFailure]::ReasonFromMessage($c.Ex.Message) |
                    Should -Be $c.Reason -Because $c.Ex.GetType().Name
            }
        }
        It "tolerates the worker's 'Worker failed: ' prefix" {
            $prefixed = "Worker failed: Host 'h' is offline or unreachable (no response)."
            [string][RemoteFailure]::ReasonFromMessage($prefixed) | Should -Be 'Offline'
        }
        It "returns Unknown for blank or unrecognized messages" {
            [string][RemoteFailure]::ReasonFromMessage('')              | Should -Be 'Unknown'
            [string][RemoteFailure]::ReasonFromMessage($null)           | Should -Be 'Unknown'
            [string][RemoteFailure]::ReasonFromMessage('disk full lol') | Should -Be 'Unknown'
        }
    }
}
