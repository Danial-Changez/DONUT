using module "..\..\src\Services\PendingIntentStore.psm1"
using module "..\..\src\Models\PendingIntent.psm1"
using module "..\..\src\Core\DonutPaths.psm1"

<#
    The elevation handover, for real: the REAL store against the REAL data root
    (redirected), including a second pwsh process claiming the note - the exact
    shape of the de-elevated-writes / elevated-reads round trip.
#>
Describe "Pending intent on the real data root" {

    BeforeAll {
        $script:originalProgramData = $env:ProgramData
        $script:testRoot = Join-Path $env:TEMP "DonutIntentIntegration_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -Path $script:testRoot -ItemType Directory -Force | Out-Null
        $env:ProgramData = $script:testRoot
        $script:repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..' '..')).Path
    }

    AfterAll {
        $env:ProgramData = $script:originalProgramData
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "round-trips a note through the real pending-intent.json" {
        $store = [PendingIntentStore]::new($null)
        $store.Save([PendingIntent]::Create([GatedAction]::DiskScan, @('PC-1'), [datetime]::UtcNow))

        $path = $store.IntentPath()
        Test-Path -LiteralPath $path | Should -BeTrue

        $taken = $store.Take([datetime]::UtcNow)
        $taken.Action | Should -Be ([GatedAction]::DiskScan)
        $taken.Hosts | Should -Be @('PC-1')
        Test-Path -LiteralPath $path | Should -BeFalse
        $store.Take([datetime]::UtcNow) | Should -BeNullOrEmpty
    }

    It "a second process claims the note exactly once (the elevation handover)" {
        $store = [PendingIntentStore]::new($null)
        $store.Save([PendingIntent]::Create([GatedAction]::RunAll, @('PC-1', 'PC-2'), [datetime]::UtcNow))

        # The claimant is a real child pwsh, like the elevated relaunch: it inherits
        # the redirected data root and runs the real store code against real files.
        $claimant = Join-Path $script:testRoot 'claim-intent.ps1'
        @"
using module "$($script:repoRoot)/src/Services/PendingIntentStore.psm1"
using module "$($script:repoRoot)/src/Models/PendingIntent.psm1"
`$taken = [PendingIntentStore]::new(`$null).Take([datetime]::UtcNow)
@{
    got    = (`$null -ne `$taken)
    action = if (`$taken) { [string]`$taken.Action } else { '' }
    hosts  = if (`$taken) { @(`$taken.Hosts) } else { @() }
} | ConvertTo-Json | Set-Content -LiteralPath `$args[0]
"@ | Set-Content -Path $claimant

        $verdictPath = Join-Path $script:testRoot 'claim-verdict.json'
        & ([System.Environment]::ProcessPath) -NoProfile -File $claimant $verdictPath
        $LASTEXITCODE | Should -Be 0

        $verdict = Get-Content -LiteralPath $verdictPath -Raw | ConvertFrom-Json
        $verdict.got | Should -BeTrue
        $verdict.action | Should -Be 'RunAll'
        @($verdict.hosts) | Should -Be @('PC-1', 'PC-2')

        # Claimed by the child; nothing is left for this process.
        Test-Path -LiteralPath $store.IntentPath() | Should -BeFalse
        $store.Take([datetime]::UtcNow) | Should -BeNullOrEmpty
    }

    It "a stale note on disk is consumed, not resumed" {
        $store = [PendingIntentStore]::new($null)
        $store.Save([PendingIntent]::Create([GatedAction]::Run, @('PC-1'), [datetime]::UtcNow.AddHours(-3)))

        $store.Take([datetime]::UtcNow) | Should -BeNullOrEmpty
        Test-Path -LiteralPath $store.IntentPath() | Should -BeFalse
    }
}
