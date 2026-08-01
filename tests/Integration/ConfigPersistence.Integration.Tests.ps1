using module "..\..\src\Core\ConfigManager.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Services\RecentConnectionsStore.psm1"

<#
    Persistence through the REAL config.json on a redirected data root: the
    recents/owner round trip an app restart depends on, and the corrupt-file
    fallback. Complements ConfigManager unit tests, which stay in-memory.
#>
Describe "Config persistence on the real data root" {

    BeforeAll {
        $script:originalProgramData = $env:ProgramData
        $script:originalLocalAppData = $env:LOCALAPPDATA
        $script:testRoot = Join-Path $env:TEMP "DonutConfigIntegration_$([Guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:testSourceRoot = Join-Path $script:testRoot 'src'
        New-Item -Path $script:testSourceRoot -ItemType Directory -Force | Out-Null
        $env:ProgramData = $script:testRoot
        $env:LOCALAPPDATA = $script:testRoot
    }

    AfterAll {
        $env:ProgramData = $script:originalProgramData
        $env:LOCALAPPDATA = $script:originalLocalAppData
        Remove-Item -Path $script:testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "recent hosts and their owners survive an app restart" {
        # First app run: mutate the store, which persists through ConfigManager.
        $manager1 = [ConfigManager]::new($script:testSourceRoot)
        $config1 = $manager1.LoadConfig()
        $store1 = [RecentConnectionsStore]::new($config1, $manager1)
        $store1.Upsert('PC-ROUNDTRIP', 'Completed', 'Scan', 3, $false)
        $store1.UpsertOwner('PC-ROUNDTRIP', 'PC-ROUNDTRIP (Danial C)')
        $store1.FlushSave()

        # Second app run: fresh manager + store must rehydrate from config.json.
        $manager2 = [ConfigManager]::new($script:testSourceRoot)
        $config2 = $manager2.LoadConfig()
        $store2 = [RecentConnectionsStore]::new($config2, $manager2)

        $row = $store2.GetByHost('PC-ROUNDTRIP')
        $row | Should -Not -BeNullOrEmpty
        $row.Owner | Should -Be 'PC-ROUNDTRIP (Danial C)'
    }

    It "a corrupt config.json falls back to defaults instead of throwing" {
        $manager = [ConfigManager]::new($script:testSourceRoot)
        $manager.SaveConfig($manager.LoadConfig())
        $configFile = Get-ChildItem -Path $script:testRoot -Recurse -Filter 'config.json' |
            Select-Object -First 1
        $configFile | Should -Not -BeNullOrEmpty

        Set-Content -LiteralPath $configFile.FullName -Value '{ not valid json at all'

        $reloaded = ([ConfigManager]::new($script:testSourceRoot)).LoadConfig()
        $reloaded | Should -Not -BeNullOrEmpty
        $reloaded.GetType().Name | Should -Be 'AppConfig'
    }
}
