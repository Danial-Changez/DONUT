using module "..\..\src\Models\DeviceFlowDecision.psm1"

Describe "DeviceFlowDecision" {
    Context "FromPollResult" {
        It "Maps an authorized result to Authorized and carries the token data" {
            $token = [pscustomobject]@{ access_token = 'abc' }
            $result = [pscustomobject]@{ Status = 'authorized'; TokenData = $token }

            $d = [DeviceFlowDecision]::FromPollResult($result)

            $d.Outcome   | Should -Be ([PollOutcome]::Authorized)
            $d.TokenData | Should -Be $token
        }

        It "Maps a pending result to KeepPolling" {
            $d = [DeviceFlowDecision]::FromPollResult([pscustomobject]@{ Status = 'pending' })
            $d.Outcome | Should -Be ([PollOutcome]::KeepPolling)
        }

        It "Maps a slow_down result to SlowDown" {
            $d = [DeviceFlowDecision]::FromPollResult([pscustomobject]@{ Status = 'slow_down' })
            $d.Outcome | Should -Be ([PollOutcome]::SlowDown)
        }

        It "Maps a terminal error to Failed with a user-facing message" {
            $d = [DeviceFlowDecision]::FromPollResult([pscustomobject]@{ Status = 'error'; Error = 'expired_token' })

            $d.Outcome | Should -Be ([PollOutcome]::Failed)
            $d.Message | Should -BeLike '*expired_token*'
        }

        It "Treats a null result as KeepPolling (transient hiccup)" {
            $d = [DeviceFlowDecision]::FromPollResult($null)
            $d.Outcome | Should -Be ([PollOutcome]::KeepPolling)
        }

        It "Treats an unknown status as Failed" {
            $d = [DeviceFlowDecision]::FromPollResult([pscustomobject]@{ Status = 'weird'; Error = 'weird' })
            $d.Outcome | Should -Be ([PollOutcome]::Failed)
        }
    }
}
