using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\RecentConnection.psm1"
using module "..\..\src\Services\RecentConnectionsStore.psm1"

Describe "RecentConnectionsStore" {

    BeforeEach {
        # A real file under TestDrive, and a $null logger coalesces to the no-op.
        $script:path = Join-Path $TestDrive "recents_$(Get-Random).json"
        $script:store = [RecentConnectionsStore]::new($script:path, $null)
    }

    Context "Upsert" {
        It "Inserts a new host with a fresh lastSeen" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-1"
            $all[0].LastStatus | Should -Be "Completed"
            $all[0].LastSeen | Should -Not -BeNullOrEmpty
        }

        It "Replaces an existing host (case-insensitive) rather than duplicating" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $script:store.Upsert("pc-1", "Failed", "UpdateApply", 3)

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].LastStatus | Should -Be "Failed"
            $all[0].UpdateCount | Should -Be 3
        }

        It "Persists to recents.json as a JSON array of entries" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2)

            $raw = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
            @($raw).Count | Should -Be 1
            @($raw)[0]['hostname'] | Should -Be "PC-1"
        }
    }

    Context "File round-trip (an app restart)" {
        It "Rehydrates entries with owner + touch intact from the file" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2)
            $script:store.UpsertOwner("PC-1", "Jamie Doe")
            $script:store.Touch("PC-1")

            $reloaded = [RecentConnectionsStore]::new($script:path, $null)

            $rc = $reloaded.GetByHost('PC-1')
            $rc.LastStatus  | Should -Be "Completed"
            $rc.UpdateCount | Should -Be 2
            $rc.Owner       | Should -Be "Jamie Doe"
            $rc.LastTouched | Should -Not -BeNullOrEmpty
        }

        It "Starts empty (without throwing) from a corrupt file" {
            Set-Content -LiteralPath $script:path -Value '{ not valid json at all'

            $reloaded = [RecentConnectionsStore]::new($script:path, $null)

            $reloaded.Count() | Should -Be 0
        }

        It "Starts empty when the file does not exist yet" {
            $script:store.Count() | Should -Be 0
        }

        It "Serializes a single entry as an array (no shape flip on reload)" {
            $script:store.Upsert("ONLY-ONE", "Completed", "Scan", 0)

            $reloaded = [RecentConnectionsStore]::new($script:path, $null)
            $reloaded.GetAll().Count | Should -Be 1
        }
    }

    Context "GetAll ordering and cap" {
        It "Returns most-recently-seen first" {
            $script:store.Upsert("OLD", "Completed", "Scan", 0)
            Start-Sleep -Milliseconds 10
            $script:store.Upsert("NEW", "Completed", "Scan", 0)

            $all = $script:store.GetAll()
            $all[0].Hostname | Should -Be "NEW"
            $all[1].Hostname | Should -Be "OLD"
        }

        It "Caps the STORED entries at the static Cap (the file cannot grow unbounded)" {
            for ($i = 0; $i -lt ([RecentConnectionsStore]::Cap + 10); $i++) {
                $script:store.Upsert("PC-$i", "Completed", "Scan", 0)
            }

            $script:store.GetAll().Count | Should -Be ([RecentConnectionsStore]::Cap)
            # The trim must have landed on write, not just on read.
            $reloaded = [RecentConnectionsStore]::new($script:path, $null)
            $reloaded.Count() | Should -Be ([RecentConnectionsStore]::Cap)
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
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $seenBefore = $script:store.GetByHost("PC-1").LastSeen

            $script:store.Touch("PC-1")

            $script:store.GetByHost("PC-1").LastSeen | Should -Be $seenBefore
            $script:store.GetByHost("PC-1").LastTouched | Should -Not -BeNullOrEmpty
        }

        It "Orders a freshly-touched host ahead of an older-run one" {
            $script:store.Upsert("RAN-EARLIER", "Completed", "Scan", 0)
            Start-Sleep -Milliseconds 10
            $script:store.Touch("ADDED-NOW")

            $script:store.GetAll()[0].Hostname | Should -Be "ADDED-NOW"
        }

        It "A newer run outranks an older touch (most recent activity wins)" {
            $script:store.Touch("TOUCHED-FIRST")
            Start-Sleep -Milliseconds 10
            $script:store.Upsert("RAN-AFTER", "Completed", "Scan", 0)

            $script:store.GetAll()[0].Hostname | Should -Be "RAN-AFTER"
        }
    }

    Context "Upsert carry-over (a run must not lose the caches)" {
        It "Sheds a legacy inventory blob on the next settle (reports\ is the store)" {
            $legacy = @(@{ hostname = 'PC-1'; lastSeen = ''; lastStatus = ''; lastJobType = ''
                    updateCount = 0; inventory = @{ model = 'Latitude 5440' }
                })
            ConvertTo-Json -InputObject $legacy -Depth 5 | Set-Content -LiteralPath $script:path
            $legacyStore = [RecentConnectionsStore]::new($script:path, $null)

            $legacyStore.Upsert("PC-1", "Completed", "Scan", 2)

            $raw = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
            @($raw)[0].ContainsKey('inventory') | Should -BeFalse
        }

        It "Keeps the lastTouched stamp across a later Upsert" {
            $script:store.Touch("PC-1")
            $touched = $script:store.GetByHost("PC-1").LastTouched

            $script:store.Upsert("PC-1", "Completed", "Scan", 0)

            $script:store.GetByHost("PC-1").LastTouched | Should -Be $touched
        }

        It "Keeps the cached owner across a later Upsert" {
            # Owner comes from a Lens round trip, so a run settling must not force a re-fetch.
            $script:store.UpsertOwner("PC-1", "Jamie Doe")

            $script:store.Upsert("PC-1", "Completed", "Scan", 0)

            $script:store.GetByHost("PC-1").Owner | Should -Be "Jamie Doe"
        }
    }

    Context "GetByHost (indexed lookup)" {
        It "Returns the entry for a known host (case-insensitive)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2)
            $script:store.Upsert("PC-2", "Failed", "UpdateApply", 0)

            $rc = $script:store.GetByHost("pc-1")
            $rc | Should -Not -BeNullOrEmpty
            $rc.Hostname | Should -Be "PC-1"
            $rc.UpdateCount | Should -Be 2
        }

        It "Returns null for an unknown or blank host" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $script:store.GetByHost("NOPE") | Should -BeNullOrEmpty
            $script:store.GetByHost("") | Should -BeNullOrEmpty
        }

        It "Reflects mutations after the cache was already built (invalidation)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 1)
            $script:store.GetByHost("PC-1").UpdateCount | Should -Be 1   # builds the cache
            $script:store.Upsert("PC-1", "Completed", "Scan", 9)         # mutate -> must invalidate
            $script:store.GetByHost("PC-1").UpdateCount | Should -Be 9
            $script:store.Remove("PC-1")
            $script:store.GetByHost("PC-1") | Should -BeNullOrEmpty
        }
    }

    Context "Deferred saves (DeferSave / FlushSave)" {
        It "Does not write until FlushSave when DeferSave is on, then writes once" {
            $script:store.DeferSave = $true

            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $script:store.Upsert("PC-2", "Completed", "Scan", 0)
            Test-Path -LiteralPath $script:path | Should -BeFalse

            $script:store.FlushSave()
            Test-Path -LiteralPath $script:path | Should -BeTrue    # coalesced single write

            Remove-Item -LiteralPath $script:path
            $script:store.FlushSave()
            Test-Path -LiteralPath $script:path | Should -BeFalse   # nothing pending
        }

        It "Writes immediately when DeferSave is off (default)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            Test-Path -LiteralPath $script:path | Should -BeTrue
        }

        It "A blank path makes every write an in-memory no-op (test seam)" {
            $memStore = [RecentConnectionsStore]::new('', $null)
            { $memStore.Upsert("PC-1", "Completed", "Scan", 0) } | Should -Not -Throw
            $memStore.GetByHost("PC-1") | Should -Not -BeNullOrEmpty
        }
    }

    Context "Remove" {
        It "Removes the named host" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $script:store.Upsert("PC-2", "Completed", "Scan", 0)

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
            $script:store.Upsert("PC-1", "Completed", "Scan", 0)
            $script:store.SeedFrom(@("PC-2", "PC-3"))

            $all = $script:store.GetAll()
            $all.Count | Should -Be 1
            $all[0].Hostname | Should -Be "PC-1"
        }
    }

    Context "MigrateFromConfig (one-time config.json -> recents.json)" {
        BeforeEach {
            $script:saves = 0
            $script:fakeMgr = [pscustomobject]@{}
            $script:fakeMgr | Add-Member -MemberType ScriptMethod -Name SaveConfig -Value { $script:saves++ }
        }

        It "Imports legacy entries minus the per-machine blobs and strips the config keys" {
            $config = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", @{
                    recentHosts       = @(@{ hostname = 'PC-1'; lastSeen = ''; lastStatus = 'Completed'
                            lastJobType = 'Scan'; updateCount = 2; owner = 'Jamie Doe'
                            rebootRequired = $false; inventory = @{ model = 'Latitude' }
                        })
                    domainControllers = @('DC01')
                })

            [RecentConnectionsStore]::MigrateFromConfig($config, $script:fakeMgr, $script:path, $null)

            $config.Settings.ContainsKey('recentHosts') | Should -BeFalse
            $config.Settings.ContainsKey('domainControllers') | Should -BeFalse
            $script:saves | Should -Be 1

            $migrated = [RecentConnectionsStore]::new($script:path, $null)
            $rc = $migrated.GetByHost('PC-1')
            $rc.LastStatus | Should -Be 'Completed'
            $rc.Owner | Should -Be 'Jamie Doe'
            $raw = Get-Content -LiteralPath $script:path -Raw | ConvertFrom-Json -AsHashtable
            @($raw)[0].ContainsKey('inventory') | Should -BeFalse
            @($raw)[0].ContainsKey('rebootRequired') | Should -BeFalse
        }

        It "An existing recents file wins over the legacy config entries" {
            $script:store.Upsert("KEEP-ME", "Completed", "Scan", 0)
            $config = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", @{
                    recentHosts = @(@{ hostname = 'LEGACY-PC' })
                })

            [RecentConnectionsStore]::MigrateFromConfig($config, $script:fakeMgr, $script:path, $null)

            $after = [RecentConnectionsStore]::new($script:path, $null)
            $after.GetByHost('KEEP-ME') | Should -Not -BeNullOrEmpty
            $after.GetByHost('LEGACY-PC') | Should -BeNullOrEmpty
            $config.Settings.ContainsKey('recentHosts') | Should -BeFalse   # keys still removed
        }

        It "Is a no-op on an already-clean config (no file, no save)" {
            $config = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", @{})

            [RecentConnectionsStore]::MigrateFromConfig($config, $script:fakeMgr, $script:path, $null)

            Test-Path -LiteralPath $script:path | Should -BeFalse
            $script:saves | Should -Be 0
        }
    }
}
