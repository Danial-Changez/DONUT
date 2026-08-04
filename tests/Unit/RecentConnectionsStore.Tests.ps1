using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\RecentConnection.psm1"
using module "..\..\src\Services\RecentConnectionsStore.psm1"

Describe "RecentConnectionsStore" {

    BeforeEach {
        # Fresh in-memory config, no config manager (Save is a no-op).
        $script:config = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", @{})
        $script:store = [RecentConnectionsStore]::new($script:config, $null)
    }

    Context "Upsert" {
        It "Inserts a new host with a fresh lastSeen" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-1"
            $all[0].LastStatus | Should -Be "Completed"
            $all[0].LastSeen | Should -Not -BeNullOrEmpty
        }

        It "Replaces an existing host (case-insensitive) rather than duplicating" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $script:store.Upsert("pc-1", "Failed", "UpdateApply", 3, $true)

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].LastStatus | Should -Be "Failed"
            $all[0].UpdateCount | Should -Be 3
        }

        It "Persists into AppConfig.Settings['recentHosts'] as plain hashtables" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)

            $raw = @($script:config.Settings['recentHosts'])
            $raw.Count | Should -Be 1
            $raw[0] -is [hashtable] | Should -Be $true
            $raw[0]['hostname'] | Should -Be "PC-1"
        }
    }

    Context "GetAll ordering and cap" {
        It "Returns most-recently-seen first" {
            $script:store.Upsert("OLD", "Completed", "Scan", 0, $false)
            Start-Sleep -Milliseconds 10
            $script:store.Upsert("NEW", "Completed", "Scan", 0, $false)

            $all = $script:store.GetAll()
            $all[0].Hostname | Should -Be "NEW"
            $all[1].Hostname | Should -Be "OLD"
        }

        It "Caps the returned list at the static Cap" {
            for ($i = 0; $i -lt ([RecentConnectionsStore]::Cap + 10); $i++) {
                $script:store.Upsert("PC-$i", "Completed", "Scan", 0, $false)
            }
            $script:store.GetAll().Count | Should -Be ([RecentConnectionsStore]::Cap)
        }
    }

    Context "Touch (operator-action recency)" {
        It "Creates a minimal never-run entry with a lastTouched stamp" {
            $script:store.Touch("NEW-PC")

            $rc = $script:store.GetByHost("NEW-PC")
            $rc | Should -Not -BeNullOrEmpty
            $rc.LastSeen | Should -BeNullOrEmpty          # still reads "never run"
            $rc.LastTouched | Should -Not -BeNullOrEmpty
        }

        It "Does NOT stamp lastSeen on an existing entry (last run stays honest)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $seenBefore = $script:store.GetByHost("PC-1").LastSeen

            $script:store.Touch("PC-1")

            $script:store.GetByHost("PC-1").LastSeen | Should -Be $seenBefore
            $script:store.GetByHost("PC-1").LastTouched | Should -Not -BeNullOrEmpty
        }

        It "Orders a freshly-touched host ahead of an older-run one" {
            $script:store.Upsert("RAN-EARLIER", "Completed", "Scan", 0, $false)
            Start-Sleep -Milliseconds 10
            $script:store.Touch("ADDED-NOW")

            $script:store.GetAll()[0].Hostname | Should -Be "ADDED-NOW"
        }

        It "A newer run outranks an older touch (most recent activity wins)" {
            $script:store.Touch("TOUCHED-FIRST")
            Start-Sleep -Milliseconds 10
            $script:store.Upsert("RAN-AFTER", "Completed", "Scan", 0, $false)

            $script:store.GetAll()[0].Hostname | Should -Be "RAN-AFTER"
        }
    }

    Context "Upsert carry-over (a run must not lose the caches)" {
        It "Sheds a legacy inventory blob on the next settle (reports\ is the store)" {
            $entry = @{ hostname = 'PC-1'; lastSeen = ''; lastStatus = ''; lastJobType = ''
                updateCount = 0; inventory = @{ model = 'Latitude 5440' }
            }
            $script:config.Settings['recentHosts'] = @($entry)

            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)

            $raw = @($script:config.Settings['recentHosts'])
            $raw[0].ContainsKey('inventory') | Should -BeFalse
        }

        It "Keeps the lastTouched stamp across a later Upsert" {
            $script:store.Touch("PC-1")
            $touched = $script:store.GetByHost("PC-1").LastTouched

            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)

            $script:store.GetByHost("PC-1").LastTouched | Should -Be $touched
        }

        It "Keeps the cached owner across a later Upsert" {
            # Owner comes from a Lens round trip; a run settling must not force a re-fetch.
            $script:store.UpsertOwner("PC-1", "Jamie Doe")

            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)

            $script:store.GetByHost("PC-1").Owner | Should -Be "Jamie Doe"
        }
    }

    Context "GetByHost (indexed lookup)" {
        It "Returns the entry for a known host (case-insensitive)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)
            $script:store.Upsert("PC-2", "Failed", "UpdateApply", 0, $false)

            $rc = $script:store.GetByHost("pc-1")
            $rc | Should -Not -BeNullOrEmpty
            $rc.Hostname | Should -Be "PC-1"
            $rc.UpdateCount | Should -Be 2
        }

        It "Returns null for an unknown or blank host" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $script:store.GetByHost("NOPE") | Should -BeNullOrEmpty
            $script:store.GetByHost("") | Should -BeNullOrEmpty
        }

        It "Reflects mutations after the cache was already built (invalidation)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 1, $false)
            $script:store.GetByHost("PC-1").UpdateCount | Should -Be 1   # builds the cache
            $script:store.Upsert("PC-1", "Completed", "Scan", 9, $false) # mutate -> must invalidate
            $script:store.GetByHost("PC-1").UpdateCount | Should -Be 9
            $script:store.Remove("PC-1")
            $script:store.GetByHost("PC-1") | Should -BeNullOrEmpty
        }
    }

    Context "Deferred saves (DeferSave / FlushSave)" {
        It "Does not write until FlushSave when DeferSave is on, then writes once" {
            $script:saves = 0
            $fakeMgr = [pscustomobject]@{}
            $fakeMgr | Add-Member -MemberType ScriptMethod -Name SaveConfig -Value { $script:saves++ }
            $deferStore = [RecentConnectionsStore]::new($script:config, $fakeMgr)
            $deferStore.DeferSave = $true

            $deferStore.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $deferStore.Upsert("PC-2", "Completed", "Scan", 0, $false)
            $script:saves | Should -Be 0    # nothing written yet

            $deferStore.FlushSave()
            $script:saves | Should -Be 1    # coalesced into a single write

            $deferStore.FlushSave()
            $script:saves | Should -Be 1    # nothing pending -> no extra write
        }

        It "Writes immediately when DeferSave is off (default)" {
            $script:saves = 0
            $fakeMgr = [pscustomobject]@{}
            $fakeMgr | Add-Member -MemberType ScriptMethod -Name SaveConfig -Value { $script:saves++ }
            $immStore = [RecentConnectionsStore]::new($script:config, $fakeMgr)

            $immStore.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $script:saves | Should -Be 1
        }
    }

    Context "Remove" {
        It "Removes the named host" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $script:store.Upsert("PC-2", "Completed", "Scan", 0, $false)

            $script:store.Remove("PC-1")

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-2"
        }
    }

    Context "SeedFrom" {
        It "Seeds blank entries when empty, de-duplicating" {
            $script:store.SeedFrom(@("PC-1", "PC-2", "pc-1", "  ", $null))

            $all = $script:store.GetAll()
            $all.Count | Should -Be 2
            ($all.Hostname | Sort-Object) | Should -Be @("PC-1", "PC-2")
            $all[0].LastSeen | Should -Be ''
        }

        It "Does nothing when entries already exist" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            $script:store.SeedFrom(@("PC-2", "PC-3"))

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-1"
        }
    }

    Context "AppConfig merge round-trip (regression)" {
        It "Preserves recentHosts through a config merge rebuild" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)

            # Rebuild AppConfig from the merged settings, like load/worker paths do.
            $rebuilt = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", $script:config.Settings)
            $rebuiltStore = [RecentConnectionsStore]::new($rebuilt, $null)

            $all = $rebuiltStore.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-1"
        }

        It "Does not leak recentHosts into the static Defaults" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0, $false)
            [AppConfig]::Defaults.ContainsKey('recentHosts') | Should -Be $false
        }
    }

    Context "JSON round-trip (what ConfigManager.Save/Load do)" {
        It "Survives serialize/deserialize with owner + touch intact" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)
            $script:store.UpsertOwner("PC-1", "Jamie Doe")
            $script:store.Touch("PC-1")

            $reloaded = ($script:config.Settings | ConvertTo-Json -Depth 10) | ConvertFrom-Json -AsHashtable
            $reloadedStore = [RecentConnectionsStore]::new(
                [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", $reloaded), $null)

            $rc = $reloadedStore.GetByHost('PC-1')
            $rc.LastStatus  | Should -Be "Completed"
            $rc.UpdateCount | Should -Be 2
            $rc.Owner       | Should -Be "Jamie Doe"
            $rc.LastTouched | Should -Not -BeNullOrEmpty
        }
    }
}
