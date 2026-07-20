<#
    Regression guard for the "app froze mid-scan during a user search" class of bug.

    Cold-loading a worker's class/module graph takes the process-wide CLR loader
    lock; if a pool job cold-loads while the WPF dispatcher is rendering (e.g. a
    scan is streaming updates), the UI freezes until the load finishes.
    ResolutionCoordinator.WarmPool pre-loads the worker graph into every pool
    runspace at startup so no job cold-loads on the hot path - but that only helps
    if the warm covers EVERY graph a pool worker uses.

    The freeze regressed when the AD-finder (AdSearchWorker -> ActiveDirectoryService)
    and user Lens (LensLookupWorker -> PersonLensService) shipped with graphs the warm
    didn't load. These tests fail if Warm-Runspace.ps1 stops covering any pool
    worker's imports, or if WarmPool stops running it.
#>

Describe "Runspace warm coverage" {

    BeforeAll {
        $script:ScriptsDir = Join-Path $PSScriptRoot '../../src/Scripts'
        $script:WarmScript = Join-Path $ScriptsDir 'Warm-Runspace.ps1'
        $script:Coordinator = Join-Path $PSScriptRoot '../../src/UI/Presenters/ResolutionCoordinator.psm1'

        # Scripts dispatched onto the shared runspace pool (via StartPoolScript / AsyncJob).
        # A NEW pool worker must be added here *and* covered by Warm-Runspace.ps1's imports.
        $script:PoolWorkers = @(
            'RemoteWorker.ps1'      # scan / apply / inventory / disk / resolve
            'AdSearchWorker.ps1'    # AD finder fan-out
            'LensLookupWorker.ps1'  # user Lens lookup + agent warm/teardown
            'AdUnlockWorker.ps1'    # inline account unlock
        )

        # The set of module files a script imports via `using module`, as normalized
        # absolute paths (resolved relative to the script, backslashes made portable).
        function Get-UsingModulePaths([string]$scriptPath) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $scriptPath, [ref]$null, [ref]$null)
            $usings = $ast.FindAll({
                    param($n)
                    ($n -is [System.Management.Automation.Language.UsingStatementAst]) -and
                    ($n.UsingStatementKind -eq
                    [System.Management.Automation.Language.UsingStatementKind]::Module)
                }, $true)
            $dir = Split-Path $scriptPath -Parent
            $set = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($u in $usings) {
                if ($null -eq $u.Name) { continue }   # module-spec hashtable form: not used by workers
                $rel = ([string]$u.Name.Value) -replace '\\', '/'
                [void]$set.Add([System.IO.Path]::GetFullPath((Join-Path $dir $rel)))
            }
            return $set
        }
    }

    It "Warm-Runspace.ps1 exists and parses cleanly" {
        Test-Path $WarmScript | Should -BeTrue
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $WarmScript, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It "every pool worker script exists" {
        foreach ($w in $PoolWorkers) {
            Test-Path (Join-Path $ScriptsDir $w) | Should -BeTrue -Because "$w is listed as a pool worker"
        }
    }

    It "warms every module graph a pool worker imports (nothing cold-loads on the hot path)" {
        $warm = Get-UsingModulePaths $WarmScript
        foreach ($w in $PoolWorkers) {
            $needed = Get-UsingModulePaths (Join-Path $ScriptsDir $w)
            foreach ($mod in $needed) {
                $warm.Contains($mod) | Should -BeTrue -Because (
                    "$w imports $(Split-Path $mod -Leaf), so Warm-Runspace.ps1 must import it too " +
                    "or that worker cold-loads under the loader lock and can freeze the UI mid-scan")
            }
        }
    }

    It "WarmPool is wired to run Warm-Runspace.ps1" {
        (Get-Content $Coordinator -Raw) | Should -Match 'Warm-Runspace\.ps1'
    }
}
