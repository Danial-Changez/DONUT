using module "..\..\src\Services\PersonLensService.psm1"
using module "..\..\src\Models\PersonLens.psm1"

<#
    The Lens agent, for real: the only runtime exercise of LensAgent.ps1 +
    LensAgent.Common.ps1. Starts the REAL agent process against a redirected
    exchange dir, drives PersonLensService's REAL encrypted round trip through
    it, and asserts the stop.flag teardown. Off-domain the gather returns an
    errors bundle - that is a PASS: the protocol (heartbeat, AES exchange,
    atomic files, shutdown) is what this file guards, not AD/SCCM reachability.

    Windows-only until the agent's AD/SCCM helper dot-sourcing is verified to
    survive non-Windows hosts (see the integration notes in testing.md).
#>

# Overrides only agent startup: the exchange loop runs against the REAL agent
# process this file started, never a scheduled task.
class LiveAgentLensService : PersonLensService {
    LiveAgentLensService() : base('site.invalid', 'C:\Src') {}
    [string] EnsureAgent() { return '' }
}

Describe "Lens agent (real process, real exchange)" -Skip:(-not $IsWindows) {

    BeforeAll {
        $script:originalProgramData = $env:ProgramData
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:testRoot = Join-Path $env:TEMP "DonutLensAgentIntegration_$stamp"
        $env:ProgramData = $script:testRoot
        $script:exchangeDir = Join-Path $script:testRoot 'DONUT\lens-agent'
        New-Item -ItemType Directory -Path $script:exchangeDir -Force | Out-Null

        # The session key the parent side would have minted in EnsureAgent.
        $script:keyIv = [PersonLensService]::NewKeyIv()
        [IO.File]::WriteAllBytes((Join-Path $script:exchangeDir 'key.bin'), $script:keyIv)

        $agentScript = (Resolve-Path (
                Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.ps1')).Path
        # ProcessStartInfo.ArgumentList quotes each argument; Start-Process joins its
        # -ArgumentList unquoted, truncating paths with spaces (e.g. this checkout's).
        $psi = [System.Diagnostics.ProcessStartInfo]::new([System.Environment]::ProcessPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        foreach ($arg in @(
                '-NoProfile', '-File', $agentScript,
                '-ExchangeDir', $script:exchangeDir,
                '-ParentPid', "$PID",
                '-SiteServer', 'site.invalid')) {
            $psi.ArgumentList.Add($arg)
        }
        $script:agent = [System.Diagnostics.Process]::Start($psi)

        # The agent beats before its pre-warm, so this bounds bring-up, not AD.
        $script:beatPath = Join-Path $script:exchangeDir 'heartbeat.txt'
        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $script:beatPath)) {
            Start-Sleep -Milliseconds 100
        }
    }

    AfterAll {
        try {
            if ($script:agent -and -not $script:agent.HasExited) { $script:agent.Kill($true) }
        }
        catch { }
        $env:ProgramData = $script:originalProgramData
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "comes up and heartbeats within 10s" {
        Test-Path -LiteralPath $script:beatPath | Should -BeTrue -Because (
            "an agent that never beats is exactly the silent Lens failure the " +
            "heartbeat exists to surface")
        $script:agent.HasExited | Should -BeFalse
    }

    It "answers a person lookup over the real encrypted exchange" {
        $svc = [LiveAgentLensService]::new()
        $svc.TimeoutSec = 60

        $request = @{
            identity   = 'donut.integration.missing@example.invalid'
            sam        = ''
            siteServer = 'site.invalid'
        }
        $out = $svc.ExchangeRoundTrip($request, $false)

        # Parent-side failure bundles would also parse; rule each out so the text
        # provably came back decrypted from the agent's result-<id>.bin.
        $out | Should -Not -BeNullOrEmpty
        $out | Should -Not -BeLike '*Lens agent unavailable*'
        $out | Should -Not -BeLike '*session key is missing*'
        $out | Should -Not -BeLike '*did not complete within*'

        # Off-domain this is an errors bundle - it must still parse as a PersonLens.
        $lens = [PersonLens]::FromJson($out)
        $lens | Should -Not -BeNullOrEmpty
        $lens.GetType().Name | Should -Be 'PersonLens'
    }

    It "consumed this lookup's exchange files (only key.bin and heartbeat remain)" {
        @(Get-ChildItem -Path $script:exchangeDir -Filter '*.bin' -File |
                Where-Object { $_.Name -ne 'key.bin' }) | Should -BeNullOrEmpty
    }

    It "exits within 5s of stop.flag" {
        New-Item -ItemType File -Path (Join-Path $script:exchangeDir 'stop.flag') -Force | Out-Null
        $script:agent.WaitForExit(5000) | Should -BeTrue -Because (
            "an agent that outlives stop.flag would leak a de-elevated process " +
            "holding BitLocker-grade data past app close")
    }
}
