<#
    Static guards for the single-instance hand-off. A dev run inside an interactive
    shell is a process that never exits, so the lock has to be released on every path
    that ends without the window, and a successor has to wait on the lock rather than
    on the pid alone. Text-based so it runs on Linux where the WPF modules cannot load.
#>

Describe "Single-instance lock hand-off" {

    BeforeAll {
        $script:Entry = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../src/Start-Donut.ps1') -Raw
        $script:App = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../src/Scripts/DonutApp.ps1') -Raw
        $script:Launcher = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../src/Launcher/Program.cs') -Raw
    }

    It "Start-Donut.ps1 defines Clear-InstanceLock and releases before disposing" {
        $script:Entry | Should -Match 'function Clear-InstanceLock'
        $script:Entry | Should -Match 'DonutInstanceMutex\.ReleaseMutex\(\)'
        $script:Entry | Should -Match 'DonutInstanceMutex\.Dispose\(\)'
    }

    It "Start-Donut.ps1 clears the lock on its startup-failure path" {
        $script:Entry | Should -Match '(?s)Write-Error "DONUT failed to start.*?Clear-InstanceLock'
    }

    It "the elevation relaunch clears the lock before it returns" {
        $script:App | Should -Match "(?s)Relaunching elevated.*?Clear-InstanceLock\s*\r?\n\s*return"
    }

    It "the app's startup catch clears the lock" {
        $script:App | Should -Match '(?s)\} catch \{\s*Close-Splash\s*Clear-InstanceLock'
    }

    It "a successor waits on the lock itself in both hosts" {
        $script:Entry | Should -Match '(?s)AwaitPid -gt 0\) \{\s*try \{ \$createdNew = '
        $script:Entry | Should -Match 'DonutInstanceMutex\.WaitOne\(15000\)'
        $script:Launcher | Should -Match 'if \(!createdNew && successor\)'
        $script:Launcher | Should -Match 'instanceMutex\.WaitOne\(AwaitPredecessorSeconds'
    }
}
