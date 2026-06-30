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
            $ex = [RemoteExecutionException]::new('PC-4', 'DCU /scan', 500)
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'ExecutionFailed'
            $ex.ExitCode       | Should -Be 500
            $ex.Message        | Should -BeLike '*exit code 500*'
        }
        It "DcuNotInstalledException is an Error with the DcuMissing reason" {
            $ex = [DcuNotInstalledException]::new('PC-5')
            [string]$ex.Level  | Should -Be 'Error'
            [string]$ex.Reason | Should -Be 'DcuMissing'
        }
    }

    Context "RemoteFailure.ReasonFromMessage (re-derives reason across the runspace boundary)" {
        It "maps each exception's own message back to its reason" {
            [string][RemoteFailure]::ReasonFromMessage(([HostOfflineException]::new('h')).Message)      | Should -Be 'Offline'
            [string][RemoteFailure]::ReasonFromMessage(([HostUnresolvableException]::new('h')).Message) | Should -Be 'Unresolvable'
            [string][RemoteFailure]::ReasonFromMessage(([RpcUnavailableException]::new('h')).Message)   | Should -Be 'RpcUnavailable'
            [string][RemoteFailure]::ReasonFromMessage(([RemoteExecutionException]::new('h','DCU /scan',500)).Message) | Should -Be 'ExecutionFailed'
            [string][RemoteFailure]::ReasonFromMessage(([DcuNotInstalledException]::new('h')).Message)  | Should -Be 'DcuMissing'
        }
        It "tolerates the worker's 'Worker failed: ' prefix" {
            [string][RemoteFailure]::ReasonFromMessage("Worker failed: Host 'h' is offline or unreachable (no response).") | Should -Be 'Offline'
        }
        It "returns Unknown for blank or unrecognized messages" {
            [string][RemoteFailure]::ReasonFromMessage('')              | Should -Be 'Unknown'
            [string][RemoteFailure]::ReasonFromMessage($null)           | Should -Be 'Unknown'
            [string][RemoteFailure]::ReasonFromMessage('disk full lol') | Should -Be 'Unknown'
        }
    }
}
