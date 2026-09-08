using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "RunspaceManager" {

    AfterEach {
        [RunspaceManager]::Close()
        [RunspaceManager]::Logger = [NullLogService]::new()
    }

    Context "Initialize" {
        It "Should create a RunspacePool with default parameters" {
            [RunspaceManager]::Initialize(1, 5)

            $pool = [RunspaceManager]::RunspacePool
            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        }

        It "Should create a RunspacePool with custom min/max" {
            [RunspaceManager]::Initialize(2, 10)

            $pool = [RunspaceManager]::RunspacePool
            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        }

        It "Should not recreate pool if already initialized" {
            [RunspaceManager]::Initialize(1, 5)
            $firstPool = [RunspaceManager]::RunspacePool

            [RunspaceManager]::Initialize(2, 10)  # Should be ignored
            $secondPool = [RunspaceManager]::RunspacePool

            $firstPool | Should -Be $secondPool
        }

        It "raises the ThreadPool floor before opening the pool (starvation guard)" {
            # ThreadPool dispatch starves under 8 concurrent warm opens unless the floor rises.
            [RunspaceManager]::Initialize(8, 8)
            $w = 0; $io = 0
            [System.Threading.ThreadPool]::GetMinThreads([ref]$w, [ref]$io)
            $expected = [Math]::Max(16, (8 + [RunspaceManager]::InteractiveSize) * 2)
            $w | Should -BeGreaterOrEqual $expected -Because "the floor must cover both pools"
            $io | Should -BeGreaterOrEqual $expected
        }

        It "opens a separate interactive pool so lookups never queue behind worker jobs" {
            [RunspaceManager]::Initialize(8, 8)

            $worker = [RunspaceManager]::GetPool()
            $interactive = [RunspaceManager]::GetInteractivePool()
            $interactive | Should -Not -BeNullOrEmpty
            $interactive.RunspacePoolStateInfo.State | Should -Be 'Opened'
            [object]::ReferenceEquals($worker, $interactive) | Should -BeFalse
        }

        It "pins the interactive pool at min = max so warmed runspaces are not reclaimed" {
            [RunspaceManager]::Initialize(8, 8)

            $n = [RunspaceManager]::InteractiveSize
            $pool = [RunspaceManager]::GetInteractivePool()
            $pool.GetMinRunspaces() | Should -Be $n
            $pool.GetMaxRunspaces() | Should -Be $n
        }

        It "re-opens the interactive pool on demand rather than throwing at the caller" {
            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::InteractivePool.Close()
            [RunspaceManager]::InteractivePool.Dispose()
            [RunspaceManager]::InteractivePool = $null

            # No Should -Not -Throw wrapper: its child scope would swallow the assignment below.
            $pool = [RunspaceManager]::GetInteractivePool()
            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
            [object]::ReferenceEquals($pool, [RunspaceManager]::RunspacePool) | Should -BeFalse
        }
    }

    Context "SizeInteractiveFor" {

        BeforeEach { $script:SavedSize = [RunspaceManager]::InteractiveSize }
        AfterEach { [RunspaceManager]::InteractiveSize = $script:SavedSize }

        It "gives the AD fan-out one slot per forest" {
            # At 4 with ten forests every leg queued: 350-850ms searches landed seconds late.
            [RunspaceManager]::SizeInteractiveFor(10)
            [RunspaceManager]::InteractiveSize | Should -Be 10
        }

        It "floors at 4, so an undiscovered domain list keeps the old lane" {
            [RunspaceManager]::SizeInteractiveFor(0)
            [RunspaceManager]::InteractiveSize | Should -Be 4
        }

        It "caps at 12: every runspace pays a serialized compile at warm" {
            [RunspaceManager]::SizeInteractiveFor(40)
            [RunspaceManager]::InteractiveSize | Should -Be 12
        }

        It "is ignored once the pool is open, since the size is fixed by then" {
            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::SizeInteractiveFor(10)
            [RunspaceManager]::InteractiveSize | Should -Be $script:SavedSize
        }
    }

    Context "GetPool" {
        It "Should return existing pool if initialized" {
            [RunspaceManager]::Initialize(1, 5)
            $pool = [RunspaceManager]::GetPool()

            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        }

        It "Should auto-initialize if pool does not exist" {
            [RunspaceManager]::Close()

            $pool = [RunspaceManager]::GetPool()

            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
        }
    }

    Context "Close" {
        It "Should close and dispose the RunspacePool" {
            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::Close()

            [RunspaceManager]::RunspacePool | Should -BeNullOrEmpty
        }

        It "Should close and dispose the interactive pool too" {
            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::GetInteractivePool() | Should -Not -BeNullOrEmpty
            [RunspaceManager]::Close()

            [RunspaceManager]::InteractivePool | Should -BeNullOrEmpty
        }

        It "Should handle being called when pool is already null" {
            [RunspaceManager]::Close()

            { [RunspaceManager]::Close() } | Should -Not -Throw
        }
    }

    Context "Logging" {
        It "Should log pool open and close through the attached logger" {
            $logger = [CapturingLogService]::new()
            [RunspaceManager]::Logger = $logger

            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::Close()

            $logger.HasLevel("INFO") | Should -Be $true
            ($logger.Contains("opened") -and $logger.Contains("closed")) | Should -Be $true
        }

        It "Should not throw with the default no-op logger" {
            [RunspaceManager]::Logger = [NullLogService]::new()

            { [RunspaceManager]::Initialize(1, 5); [RunspaceManager]::Close() } | Should -Not -Throw
        }
    }
}
