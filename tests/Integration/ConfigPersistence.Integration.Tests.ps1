using module "..\..\src\Core\ConfigManager.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\RecentConnectionsStore.psm1"

<#
    Persistence on a redirected REAL data root: the recents/owner round trip an
    app restart depends on (config\recents.json), the one-time config.json ->
    recents.json migration, and the corrupt-config fallback. Complements the
    ConfigManager + store unit tests, which stay in-memory / on TestDrive.
#>
Describe "Config persistence on the real data root" {

    BeforeAll {
        . "$PSScriptRoot\..\Helpers\New-RedirectedDataRoot.ps1"
        $script:redirect = New-RedirectedDataRoot -Prefix 'DonutConfigIntegration'
        $script:testRoot = $script:redirect.Root
        $script:testSourceRoot = Join-Path $script:testRoot 'src'
        New-Item -Path $script:testSourceRoot `
                 -ItemType Directory `
                 -Force | Out-Null
    }

    AfterAll {
        Remove-RedirectedDataRoot $script:redirect
    }

    It "recent hosts and their owners survive an app restart via recents.json" {
        # First app run: EnsureDirectories creates config\, then the store persists.
        $manager1 = [ConfigManager]::new($script:testSourceRoot)
        $manager1.LoadConfig() | Out-Null
        $store1 = [RecentConnectionsStore]::new([RecentConnectionsStore]::DefaultPath(), $null)
        $store1.Upsert('PC-ROUNDTRIP', 'Completed', 'Scan', 3)
        $store1.UpsertOwner('PC-ROUNDTRIP', 'PC-ROUNDTRIP (Danial C)')
        $store1.FlushSave()

        # Second app run: rehydrate from recents.json, with no machine-list state in config.json.
        $store2 = [RecentConnectionsStore]::new([RecentConnectionsStore]::DefaultPath(), $null)
        $row = $store2.GetByHost('PC-ROUNDTRIP')
        $row | Should -Not -BeNullOrEmpty
        $row.Owner | Should -Be 'PC-ROUNDTRIP (Danial C)'

        $configFile = Get-ChildItem -Path $script:testRoot `
                                    -Recurse `
                                    -Filter 'config.json' |
            Select-Object -First 1
        (Get-Content -LiteralPath $configFile.FullName -Raw) | Should -Not -BeLike '*recentHosts*'
    }

    It "a legacy config.json migrates its recentHosts into recents.json once" {
        # A pre-split install: recentHosts with an inventory blob still inside config.json.
        $manager = [ConfigManager]::new($script:testSourceRoot)
        $config = $manager.LoadConfig()
        $config.Settings['recentHosts'] = @(@{ hostname = 'LEGACY-PC'; lastSeen = ''
                lastStatus = 'Completed'; lastJobType = 'Scan'; updateCount = 1
                owner = 'Jamie Doe'; inventory = @{ model = 'Latitude' }
            })
        $config.Settings['domainControllers'] = @('DC01')
        $manager.SaveConfig($config)
        $recentsPath = [RecentConnectionsStore]::DefaultPath()
        Remove-Item -LiteralPath $recentsPath `
                    -Force `
                    -ErrorAction SilentlyContinue

        # What HomePresenter's wiring does on the next launch.
        [RecentConnectionsStore]::MigrateFromConfig($config, $manager, $recentsPath, $null)
        $store = [RecentConnectionsStore]::new($recentsPath, $null)

        $rc = $store.GetByHost('LEGACY-PC')
        $rc | Should -Not -BeNullOrEmpty
        $rc.Owner | Should -Be 'Jamie Doe'

        # config.json on disk is settings-only now, and the blob did not ride along.
        $reloaded = ([ConfigManager]::new($script:testSourceRoot)).LoadConfig()
        $reloaded.Settings.ContainsKey('recentHosts') | Should -BeFalse
        $reloaded.Settings.ContainsKey('domainControllers') | Should -BeFalse
        (Get-Content -LiteralPath $recentsPath -Raw) | Should -Not -BeLike '*inventory*'
    }

    It "a corrupt config.json falls back to defaults instead of throwing" {
        $manager = [ConfigManager]::new($script:testSourceRoot)
        $manager.SaveConfig($manager.LoadConfig())
        $configFile = Get-ChildItem -Path $script:testRoot `
                                    -Recurse `
                                    -Filter 'config.json' |
            Select-Object -First 1
        $configFile | Should -Not -BeNullOrEmpty

        Set-Content -LiteralPath $configFile.FullName -Value '{ not valid json at all'

        $reloaded = ([ConfigManager]::new($script:testSourceRoot)).LoadConfig()
        $reloaded | Should -Not -BeNullOrEmpty
        $reloaded.GetType().Name | Should -Be 'AppConfig'
    }
}
