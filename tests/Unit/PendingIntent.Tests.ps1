using module "..\..\src\Models\PendingIntent.psm1"

Describe "PendingIntent" {

    BeforeAll {
        $script:now = [datetime]::new(2026, 7, 30, 12, 0, 0, [DateTimeKind]::Utc)
        $script:ttl = [timespan]::FromMinutes(2)
    }

    Context "Create" {
        It "stamps the action, hosts and time" {
            $i = [PendingIntent]::Create([GatedAction]::DiskScan, @('PC-1', 'PC-2'), $script:now)

            $i.Action | Should -Be ([GatedAction]::DiskScan)
            $i.Hosts | Should -Be @('PC-1', 'PC-2')
            $i.IsFresh($script:now, $script:ttl) | Should -BeTrue
        }

        It "drops blank host names rather than carrying them across" {
            $i = [PendingIntent]::Create([GatedAction]::Run, @('PC-1', '', '   ', $null), $script:now)
            $i.Hosts.Count | Should -Be 1
        }
    }

    Context "IsResumable" {
        It "refuses to resume DeleteFolders" {
            # The folder list is not carried here, so resuming would be a guess. The user re-picks.
            [PendingIntent]::Create([GatedAction]::DeleteFolders, @('PC-1'), $script:now).IsResumable() |
                Should -BeFalse
        }

        It "resumes every non-destructive action" {
            foreach ($a in @([GatedAction]::RunAll, [GatedAction]::Run, [GatedAction]::Inventory,
                    [GatedAction]::DiskScan, [GatedAction]::StartupTask)) {
                [PendingIntent]::Create($a, @('PC-1'), $script:now).IsResumable() |
                    Should -BeTrue -Because "$a carries no destructive parameters"
            }
        }
    }

    Context "IsFresh" {
        It "accepts a note inside the window" {
            $i = [PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now.AddSeconds(-30))
            $i.IsFresh($script:now, $script:ttl) | Should -BeTrue
        }

        It "rejects a note older than the window" {
            # A file left behind by a crash must not fire hours or days later.
            $i = [PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now.AddMinutes(-10))
            $i.IsFresh($script:now, $script:ttl) | Should -BeFalse
        }

        It "rejects a note stamped in the future" {
            # Clock skew or tampering, and either way it is not a click that just happened.
            $i = [PendingIntent]::Create([GatedAction]::Run, @('PC-1'), $script:now.AddMinutes(5))
            $i.IsFresh($script:now, $script:ttl) | Should -BeFalse
        }

        It "rejects an unstamped or unparseable time" {
            $i = [PendingIntent]::new()
            $i.IsFresh($script:now, $script:ttl) | Should -BeFalse
            $i.CreatedUtc = 'not-a-date'
            $i.IsFresh($script:now, $script:ttl) | Should -BeFalse
        }
    }

    Context "JSON round-trip" {
        It "survives ToJson then FromJson" {
            $original = [PendingIntent]::Create([GatedAction]::DiskScan, @('PC-1', 'PC-2'), $script:now)
            $back = [PendingIntent]::FromJson($original.ToJson())

            $back.Action | Should -Be ([GatedAction]::DiskScan)
            $back.Hosts | Should -Be @('PC-1', 'PC-2')
            $back.IsFresh($script:now, $script:ttl) | Should -BeTrue
        }

        It "writes the action by NAME, not its ordinal" {
            # An enum serialized as its integer would re-read as a different action after an insert.
            [PendingIntent]::Create([GatedAction]::DiskScan, @(), $script:now).ToJson() |
                Should -BeLike '*"action":"DiskScan"*'
        }

        It "returns null for anything it cannot vouch for" {
            # Untrusted input: a de-elevated process writes this and an elevated one reads it.
            [PendingIntent]::FromJson('') | Should -BeNullOrEmpty
            [PendingIntent]::FromJson('   ') | Should -BeNullOrEmpty
            [PendingIntent]::FromJson('not json at all') | Should -BeNullOrEmpty
            [PendingIntent]::FromJson('{"hosts":["PC-1"]}') | Should -BeNullOrEmpty
            [PendingIntent]::FromJson('{"action":"FormatEverything","hosts":[]}') | Should -BeNullOrEmpty
            [PendingIntent]::FromJson('{"action":3,"hosts":[]}') | Should -BeNullOrEmpty
        }

        It "parses a known action case-insensitively" {
            [PendingIntent]::FromJson('{"action":"diskscan","hosts":["PC-1"],"createdUtc":""}').Action |
                Should -Be ([GatedAction]::DiskScan)
        }
    }
}
