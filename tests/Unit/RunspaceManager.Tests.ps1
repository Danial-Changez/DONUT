using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

Describe "RunspaceManager" {

    AfterEach {
        # Clean up after each test to ensure isolation
        [RunspaceManager]::Close()
        [RunspaceManager]::SetLogger($null)
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
            # Pool dispatch/completion run on ThreadPool threads; the floor MUST be
            # raised or 8 concurrent warm opens starve dispatch (see implementation-notes).
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

            # A throw here fails the test on its own - no Should -Not -Throw wrapper, whose
            # child scope would swallow the assignment.
            $pool = [RunspaceManager]::GetInteractivePool()
            $pool | Should -Not -BeNullOrEmpty
            $pool.RunspacePoolStateInfo.State | Should -Be 'Opened'
            [object]::ReferenceEquals($pool, [RunspaceManager]::RunspacePool) | Should -BeFalse
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
            # Ensure pool is closed
            [RunspaceManager]::Close()
            
            # GetPool calls Initialize internally - need to handle no-arg call
            # The class implementation calls Initialize() with no args which requires default params
            # This tests that GetPool works when pool is null
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
            [RunspaceManager]::Close()  # First close

            # Should not throw
            { [RunspaceManager]::Close() } | Should -Not -Throw
        }
    }

    Context "Logging" {
        It "Should log pool open and close through the attached logger" {
            $logger = [CapturingLogService]::new()
            [RunspaceManager]::SetLogger($logger)

            [RunspaceManager]::Initialize(1, 5)
            [RunspaceManager]::Close()

            $logger.HasLevel("INFO") | Should -Be $true
            ($logger.Contains("opened") -and $logger.Contains("closed")) | Should -Be $true
        }

        It "Should not throw when no logger is attached" {
            [RunspaceManager]::SetLogger($null)

            { [RunspaceManager]::Initialize(1, 5); [RunspaceManager]::Close() } | Should -Not -Throw
        }
    }
}
