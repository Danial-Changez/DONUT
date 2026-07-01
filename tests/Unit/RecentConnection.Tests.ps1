using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\MachineInventory.psm1"
using module "..\..\src\Models\RecentConnection.psm1"

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
            $all[0].RebootRequired | Should -Be $true
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

    Context "Inventory cache (UpsertInventory)" {
        BeforeEach {
            $script:inv = [MachineInventory]::new()
            $script:inv.Model = 'Latitude 5340'
            $script:inv.ServiceTag = 'ABC1234'
            $script:inv.HasBattery = $true
            $script:inv.DesignCapacity = 50000
            $script:inv.FullChargeCapacity = 45000
            $script:inv.ChargePercent = 67
        }

        It "Caches inventory on a tracked host without clobbering its status" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 4, $true)
            $script:store.UpsertInventory("PC-1", $script:inv)

            $rc = $script:store.GetAll() | Where-Object { $_.Hostname -eq 'PC-1' }
            $rc.LastStatus     | Should -Be "Completed"
            $rc.UpdateCount    | Should -Be 4
            $rc.RebootRequired | Should -Be $true
            $rc.Inventory               | Should -Not -BeNullOrEmpty
            $rc.Inventory.Model         | Should -Be 'Latitude 5340'
            $rc.Inventory.ServiceTag    | Should -Be 'ABC1234'
            $rc.Inventory.ProbedAt      | Should -Not -BeNullOrEmpty
        }

        It "Creates an entry when the host is not yet tracked" {
            $script:store.UpsertInventory("NEWPC", $script:inv)

            $rc = $script:store.GetAll() | Where-Object { $_.Hostname -eq 'NEWPC' }
            $rc                 | Should -Not -BeNullOrEmpty
            $rc.Inventory.Model | Should -Be 'Latitude 5340'
            $rc.LastStatus      | Should -Be ''
        }

        It "Survives JSON serialize/deserialize (nested inventory round-trips)" {
            $script:store.Upsert("PC-1", "Completed", "Scan", 2, $false)
            $script:store.UpsertInventory("PC-1", $script:inv)

            # Exactly what ConfigManager.Save/Load do.
            $reloaded = ($script:config.Settings | ConvertTo-Json -Depth 10) | ConvertFrom-Json -AsHashtable
            $reloadedStore = [RecentConnectionsStore]::new(
                [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", $reloaded), $null)

            $rc = $reloadedStore.GetAll() | Where-Object { $_.Hostname -eq 'PC-1' }
            $rc.Inventory                    | Should -Not -BeNullOrEmpty
            $rc.Inventory.ServiceTag         | Should -Be 'ABC1234'
            $rc.Inventory.FullChargeCapacity | Should -Be 45000
            $rc.Inventory.ChargePercent      | Should -Be 67
            $rc.LastStatus                   | Should -Be "Completed"
        }
    }
}
