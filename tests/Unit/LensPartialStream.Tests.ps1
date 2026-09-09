Describe "Lens partial delivery" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] binds live inside script blocks.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:bundle = @{ upn = 'jdoe@corp.com'; devices = @(@{ name = 'WS-1' }) }
    }

    Context "in process, where there is no exchange dir" {

        It "streams the bundle on the Information stream PollLens reads" {
            # Only so 6>&1 captures it; PowerShell.Invoke collects it either way.
            $InformationPreference = 'Continue'
            $script:ExchangeDir = ''

            $records = @(Write-LensPartial -Bundle $script:bundle `
                                           -ReqId '' `
                                           -Seq 1 6>&1)

            @($records).Count | Should-Be 1
            ($records[0].Tags -contains 'LensPartial') | Should-BeTrue
            ([string]$records[0].MessageData | ConvertFrom-Json).upn | Should-Be 'jdoe@corp.com'
        }
    }

    Context "across the exchange, where the file is the transport" {

        # The integration test covers the file write; this covers not ALSO streaming.
        It "streams nothing, so the parent never publishes the same partial twice" {
            $InformationPreference = 'Continue'
            $script:ExchangeDir = Join-Path ([IO.Path]::GetTempPath()) 'donut-lens-none'

            $records = @(Write-LensPartial -Bundle $script:bundle `
                                           -ReqId 'abc123' `
                                           -Seq 2 6>&1)

            @($records | Where-Object { $_.Tags -contains 'LensPartial' }).Count | Should-Be 0
        }
    }
}
