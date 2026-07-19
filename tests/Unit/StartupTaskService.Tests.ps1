using module "..\..\src\Services\StartupTaskService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Captures which CIM seam Apply dispatched to, without touching Task Scheduler.
#   Existing: the task GetExistingTask() should return (null = not installed)
#   Registered/Unregistered: how many times each seam ran
#   LastSpec: the spec RegisterTask received
class FakeStartupTaskService : StartupTaskService {
    [object] $Existing = $null
    [int] $Registered = 0
    [int] $Unregistered = 0
    [hashtable] $LastSpec

    FakeStartupTaskService([LogService]$logger, [string]$sourceRoot)
    : base($logger, $null, $sourceRoot) { }

    hidden [object] GetExistingTask() { return $this.Existing }
    hidden [void] RegisterTask([hashtable]$spec) { $this.Registered++; $this.LastSpec = $spec }
    hidden [void] UnregisterTask() { $this.Unregistered++ }
}

# Its register seam throws (simulates a non-elevated Register-ScheduledTask) so the
# test can assert Apply swallows it and logs instead of propagating.
class ThrowingStartupTaskService : StartupTaskService {
    [object] $Existing = $null
    ThrowingStartupTaskService([LogService]$logger, [string]$sourceRoot)
    : base($logger, $null, $sourceRoot) { }
    hidden [object] GetExistingTask() { return $this.Existing }
    hidden [void] RegisterTask([hashtable]$spec) { throw "access denied (not elevated)" }
}

BeforeAll {
    # A fake existing task whose action matches (or differs from) a spec.
    function New-FakeTask([string]$execute, [string]$arguments) {
        return [pscustomobject]@{
            Actions = @([pscustomobject]@{ Execute = $execute; Arguments = $arguments })
        }
    }
}

Describe "StartupTaskService" {

    BeforeAll {
        $script:logger = [CapturingLogService]::new()
        $script:svc = [StartupTaskService]::new($script:logger, $null, 'C:\App\src')
    }

    Context "TaskName" {
        It "Is per-user (DONUT-<username>)" {
            [StartupTaskService]::TaskName() | Should -Be "DONUT-$env:USERNAME"
        }
    }

    Context "BuildLaunchSpec" {
        It "Uses -File ...Start-Donut.ps1 -Tray for a pwsh.exe host" {
            $spec = $script:svc.BuildLaunchSpec('C:\Program Files\PowerShell\7\pwsh.exe', 'C:\My App\src')
            $spec.Execute | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
            $spec.Argument | Should -Be '-Sta -ExecutionPolicy Bypass -File "C:\My App\src\Start-Donut.ps1" -Tray'
        }

        It "Quotes the script path so spaces/OneDrive survive" {
            $spec = $script:svc.BuildLaunchSpec('C:\pwsh.exe', 'C:\Users\x\OneDrive\DONUT\src')
            $spec.Argument | Should -BeLike '*-File "C:\Users\x\OneDrive\DONUT\src\Start-Donut.ps1" -Tray*'
        }

        It "Uses --tray for the packaged launcher exe" {
            $spec = $script:svc.BuildLaunchSpec('C:\Program Files\DONUT\Donut.Launcher.exe', 'C:\ignored')
            $spec.Execute | Should -Be 'C:\Program Files\DONUT\Donut.Launcher.exe'
            $spec.Argument | Should -Be '--tray'
        }

        It "Matches pwsh.exe case-insensitively" {
            $spec = $script:svc.BuildLaunchSpec('C:\Tools\PWSH.EXE', 'C:\src')
            $spec.Argument | Should -BeLike '*-Tray'
        }
    }

    Context "ReconcileDecision matrix" {
        BeforeAll {
            $script:spec = @{ Execute = 'C:\pwsh.exe'; Argument = '--x' }
            $script:matching = New-FakeTask 'C:\pwsh.exe' '--x'
            $script:differing = New-FakeTask 'C:\old\pwsh.exe' '--x'
        }

        It "enabled + no task => Register" {
            $script:svc.ReconcileDecision($true, $null, $script:spec) | Should -Be 'Register'
        }
        It "enabled + matching task => NoOp" {
            $script:svc.ReconcileDecision($true, $script:matching, $script:spec) | Should -Be 'NoOp'
        }
        It "enabled + differing action => Reregister" {
            $script:svc.ReconcileDecision($true, $script:differing, $script:spec) | Should -Be 'Reregister'
        }
        It "disabled + task present => Unregister" {
            $script:svc.ReconcileDecision($false, $script:matching, $script:spec) | Should -Be 'Unregister'
        }
        It "disabled + no task => NoOp" {
            $script:svc.ReconcileDecision($false, $null, $script:spec) | Should -Be 'NoOp'
        }
        It "Treats a task with a differing argument as Reregister" {
            $argDiff = New-FakeTask 'C:\pwsh.exe' '--other'
            $script:svc.ReconcileDecision($true, $argDiff, $script:spec) | Should -Be 'Reregister'
        }
    }

    Context "Apply dispatch (fake CIM seams)" {
        It "Registers when enabled and no task exists" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Existing = $null
            $fake.Apply($true) | Should -BeTrue
            $fake.Registered | Should -Be 1
            $fake.Unregistered | Should -Be 0
        }

        It "Unregisters when disabled and a task exists" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Existing = New-FakeTask 'C:\any.exe' '--tray'
            $fake.Apply($false)
            $fake.Unregistered | Should -Be 1
            $fake.Registered | Should -Be 0
        }

        It "Does nothing when disabled and no task exists" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Existing = $null
            $fake.Apply($false)
            $fake.Registered | Should -Be 0
            $fake.Unregistered | Should -Be 0
        }

        It "Never throws to the caller when a seam fails" {
            $logger = [CapturingLogService]::new()
            $throwing = [ThrowingStartupTaskService]::new($logger, 'C:\App\src')
            $throwing.Existing = $null
            { $throwing.Apply($true) } | Should -Not -Throw
            $logger.HasLevel('ERROR') | Should -BeTrue
        }
    }
}
