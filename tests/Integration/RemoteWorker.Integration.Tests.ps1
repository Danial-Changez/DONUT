using module "..\..\src\Models\RemoteError.psm1"

<#
    The worker's legacy named-parameter entry (the shape WarmPool uses in-runspace),
    run as a direct child process and pinned to its FAILURE contract: exit 1 plus ONE
    clean 'Worker failed: ...' line on stderr - no Write-Error decoration - because
    the parent derives the typed RemoteFailureReason from exactly that text
    (RemoteFailure.ReasonFromMessage). The production ArgsFile/ResultFile transport
    is covered by WorkerProtocol.Integration.Tests.ps1.
#>
Describe "RemoteWorker legacy entry (failure contract)" {

    BeforeAll {
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $script:testRoot = Join-Path $env:TEMP "DonutRemoteWorkerLegacy_$stamp"
        $script:logsDir = Join-Path $script:testRoot 'logs'
        $script:reportsDir = Join-Path $script:testRoot 'reports'
        New-Item -Path $script:logsDir, $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:scriptPath = (Resolve-Path (
                Join-Path $PSScriptRoot '..\..\src\Scripts\RemoteWorker.ps1')).Path
        $script:srcRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\src')).Path
    }

    AfterAll {
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "fails a doomed job with exit 1 and one parseable 'Worker failed:' stderr line" {
        $badHost = 'donut-legacy-no-such-host-99'
        # ProcessStartInfo.ArgumentList quotes each argument; Start-Process joins its
        # -ArgumentList unquoted, truncating paths with spaces (e.g. this checkout's).
        $psi = [System.Diagnostics.ProcessStartInfo]::new([System.Environment]::ProcessPath)
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardError = $true
        foreach ($arg in @(
                '-NoProfile', '-File', $script:scriptPath,
                '-HostName', $badHost,
                '-JobType', 'Scan',
                '-SourceRoot', $script:srcRoot,
                '-LogsDir', $script:logsDir,
                '-ReportsDir', $script:reportsDir)) {
            $psi.ArgumentList.Add($arg)
        }
        $p = [System.Diagnostics.Process]::Start($psi)
        $stderr = $p.StandardError.ReadToEnd()
        $p.WaitForExit()

        $p.ExitCode | Should -Be 1

        # One clean line, no Write-Error decoration: the parent parses this text as-is.
        $lines = @($stderr -split "`r?`n" | Where-Object { $_ })
        $lines.Count | Should -Be 1 -Because (
            "extra stderr lines would corrupt the FailureMessage the UI classifies")
        $lines[0] | Should -Match '^Worker failed: '
        $lines[0] | Should -Not -Match 'FullyQualifiedErrorId|CategoryInfo|Write-Error'

        # The text must still carry the typed reason the UI badge shows.
        [RemoteFailure]::ReasonFromMessage($lines[0]) |
            Should -Be ([RemoteFailureReason]::Unresolvable)

        # And the child's LogService wrote the host-tagged attempt where the UI reads it.
        $logFile = Join-Path $script:logsDir 'Donut.log'
        Test-Path -LiteralPath $logFile | Should -BeTrue
        (Get-Content -LiteralPath $logFile -Raw) | Should -Match "\[$badHost\]"
    }
}
