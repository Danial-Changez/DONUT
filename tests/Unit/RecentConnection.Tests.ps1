using module "..\..\src\Models\AppConfig.psm1"
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
}
