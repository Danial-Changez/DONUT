using module "..\..\src\Services\PendingIntentStore.psm1"
using module "..\..\src\Models\PendingIntent.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Fake that overrides the filesystem seams so claim/discard behaviour is exercised
# off-disk. Text holds the file's content, and $null means the file does not exist.
class FakeIntentStore : PendingIntentStore {
    [string] $Text = $null
    [int] $Deletes = 0
    [bool] $ThrowOnRead = $false

    FakeIntentStore([LogService]$logger) : base($logger) { }

    hidden [bool] FileExists([string]$path) { return $null -ne $this.Text }
    hidden [string] ReadText([string]$path) {
        if ($this.ThrowOnRead) { throw "boom" }
        return $this.Text
    }
    hidden [void] WriteText([string]$path, [string]$text) { $this.Text = $text }
    hidden [void] DeleteFile([string]$path) { $this.Deletes++; $this.Text = $null }
}

Describe "PendingIntentStore" {

    BeforeAll {
        $script:now = [datetime]::new(2026, 7, 30, 12, 0, 0, [DateTimeKind]::Utc)
    }

    Context "Save then Take" {
        It "returns the action that was recorded" {
            $store = [FakeIntentStore]::new([CapturingLogService]::new())
            $store.Save([PendingIntent]::Create([GatedAction]::DiskScan, @('PC-1'), $script:now))

            $taken = $store.Take($script:now)
            $taken.Action | Should -Be ([GatedAction]::DiskScan)
            $taken.Hosts | Should -Be @('PC-1')
        }

        It "fires at most once" {
            # A note that survived its claim would re-run a fleet action every launch.
            $store = [FakeIntentStore]::new([CapturingLogService]::new())
            $store.Save([PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now))

            $store.Take($script:now) | Should -Not -BeNullOrEmpty
            $store.Take($script:now) | Should -BeNullOrEmpty
        }

        It "returns null when there is no note" {
            [FakeIntentStore]::new([CapturingLogService]::new()).Take($script:now) | Should -BeNullOrEmpty
        }
    }

    Context "Rejected notes" {
        It "deletes the note even when it is rejected" {
            # Every rejection path has to consume the file, or a bad note retries forever.
            foreach ($json in @('not json', '{"action":"Nope"}', '')) {
                $store = [FakeIntentStore]::new([CapturingLogService]::new())
                $store.Text = $json
                $store.Take($script:now) | Should -BeNullOrEmpty
                $store.Deletes | Should -Be 1 -Because "'$json' must not be left behind"
            }
        }

        It "drops a stale note" {
            $store = [FakeIntentStore]::new([CapturingLogService]::new())
            $store.Save([PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now.AddHours(-3)))

            $store.Take($script:now) | Should -BeNullOrEmpty
            $store.Deletes | Should -Be 1
        }

        It "never resumes DeleteFolders" {
            $store = [FakeIntentStore]::new([CapturingLogService]::new())
            $store.Save([PendingIntent]::Create([GatedAction]::DeleteFolders, @('PC-1'), $script:now))

            $store.Take($script:now) | Should -BeNullOrEmpty
            $store.Deletes | Should -Be 1 -Because "it is consumed, just not acted on"
        }

        It "survives a read failure without throwing at the caller" {
            $store = [FakeIntentStore]::new([CapturingLogService]::new())
            $store.Text = 'whatever'
            $store.ThrowOnRead = $true

            $store.Take($script:now) | Should -BeNullOrEmpty
            $store.Deletes | Should -Be 1
        }
    }

    Context "Logging" {
        It "says why a note was discarded" {
            $logger = [CapturingLogService]::new()
            $store = [FakeIntentStore]::new($logger)
            $store.Save([PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now.AddHours(-3)))
            $store.Take($script:now) | Out-Null

            $logger.Contains('stale') | Should -BeTrue
        }
    }
}
