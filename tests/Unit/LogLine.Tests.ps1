using module "..\..\src\Models\LogLine.psm1"
using module "..\..\src\Models\DcuProgress.psm1"

Describe "LogLine" {

    Context "Donut (DONUT-authored lines)" {
        It "stamps the line with HH:mm:ss and carries the severity" {
            $l = [LogLine]::Donut([LogSeverity]::Info, "Starting Scan for PC-1...")
            $l.Stamp | Should -Match '^\d{2}:\d{2}:\d{2}$'
            $l.StampText | Should -Be "$($l.Stamp)  "
            $l.Severity | Should -Be ([LogSeverity]::Info)
            $l.Text | Should -Be "Starting Scan for PC-1..."
        }

        It "makes a blank text an unstamped separator line" {
            $l = [LogLine]::Donut([LogSeverity]::Info, '')
            $l.Stamp | Should -BeNullOrEmpty
            $l.StampText | Should -BeNullOrEmpty
            $l.DisplayText | Should -BeNullOrEmpty
        }
    }

    Context "Tag / DisplayText" {
        It "tags Error and Warn; Info and Success carry no tag" {
            [LogLine]::Tag([LogSeverity]::Error) | Should -Be '[Error] '
            [LogLine]::Tag([LogSeverity]::Warn) | Should -Be '[Warn] '
            [LogLine]::Tag([LogSeverity]::Info) | Should -BeNullOrEmpty
            [LogLine]::Tag([LogSeverity]::Success) | Should -BeNullOrEmpty
        }

        It "precomputes DisplayText as tag + text (color is never the only carrier)" {
            $l = [LogLine]::Donut([LogSeverity]::Error, "Worker failed: boom")
            $l.DisplayText | Should -Be '[Error] Worker failed: boom'
            $ok = [LogLine]::Donut([LogSeverity]::Success, "Scan complete: no updates found.")
            $ok.DisplayText | Should -Be 'Scan complete: no updates found.'
        }
    }

    Context "FromWorkerLine (dcu-cli tailed lines)" {
        It "re-stamps a dcu date-time prefix down to HH:mm:ss (no double stamp)" {
            $l = [LogLine]::FromWorkerLine(
                '[2026-07-02 15:15:43] : The scan result is VALID_RESULT', [LogSeverity]::Info)
            $l.Stamp | Should -Be '15:15:43'
            $l.Text | Should -Be 'The scan result is VALID_RESULT'
            $l.Severity | Should -Be ([LogSeverity]::Info)
        }

        It "tolerates a T separator and fractional seconds in the dcu stamp" {
            $l = [LogLine]::FromWorkerLine('[2026-07-02T15:15:43.123] message', [LogSeverity]::Info)
            $l.Stamp | Should -Be '15:15:43'
            $l.Text | Should -Be 'message'
        }

        It "stamps a prefixless worker line with the current time" {
            $l = [LogLine]::FromWorkerLine('Executing: psexec.exe ...', [LogSeverity]::Info)
            $l.Stamp | Should -Match '^\d{2}:\d{2}:\d{2}$'
            $l.Text | Should -Be 'Executing: psexec.exe ...'
        }

        It "keeps the stream severity for Warning/Error records" {
            ([LogLine]::FromWorkerLine('some text', [LogSeverity]::Warn)).Severity |
                Should -Be ([LogSeverity]::Warn)
            ([LogLine]::FromWorkerLine('some text', [LogSeverity]::Error)).Severity |
                Should -Be ([LogSeverity]::Error)
        }

        It "upgrades an Info dcu line wording an error to Warn (never to Error)" {
            $l = [LogLine]::FromWorkerLine(
                '[2026-07-02 15:16:01] : Update failed to download', [LogSeverity]::Info)
            $l.Severity | Should -Be ([LogSeverity]::Warn)
        }

        It "never downgrades an Error record even without error wording" {
            $l = [LogLine]::FromWorkerLine('plain text', [LogSeverity]::Error)
            $l.Severity | Should -Be ([LogSeverity]::Error)
        }

        It "keeps the reconnect marker at position 0 so DcuProgress still detects it" {
            $marker = [DcuProgress]::ReconnectMarker
            $l = [LogLine]::FromWorkerLine("$($marker)Connection dropped; resuming tail...", [LogSeverity]::Info)
            [DcuProgress]::IsReconnectLine($l.Text) | Should -BeTrue
        }
    }

    Context "WithText" {
        It "keeps the stamp and severity, replaces the text" {
            $orig = [LogLine]::FromWorkerLine('[2026-07-02 15:15:43] : original', [LogSeverity]::Warn)
            $l = $orig.WithText('replaced')
            $l.Stamp | Should -Be '15:15:43'
            $l.Severity | Should -Be ([LogSeverity]::Warn)
            $l.Text | Should -Be 'replaced'
            $l.DisplayText | Should -Be '[Warn] replaced'
        }
    }
}
