using module "..\..\src\Services\StartupTaskService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Captures which CIM seam Apply dispatched to, without touching Task Scheduler:
# - Identity/ConsoleUser: what the identity seams report
# - Existing: the task GetExistingTask() returns (null means not installed)
# - Registered/Unregistered: how many times each seam ran
# - LastName/LastUser/LastSpec: what RegisterTask received
class FakeStartupTaskService : StartupTaskService {
    [hashtable] $Identity = @{ Name = 'PROD\jdoe'; IsSystem = $false; IsElevated = $true }
    [string] $ConsoleUser = 'PROD\jdoe'
    [object] $Existing = $null
    [int] $Registered = 0
    [int] $Unregistered = 0
    [string] $LastName
    [string] $LastUser
    [hashtable] $LastSpec

    FakeStartupTaskService([LogService]$logger, [string]$sourceRoot)
    : base($logger, $null, $sourceRoot) { }

    [int] $StaleSweeps = 0

    hidden [hashtable] GetProcessIdentity() { return $this.Identity }
    hidden [string] GetInteractiveUser() { return $this.ConsoleUser }
    hidden [object] GetExistingTask([string]$name) { return $this.Existing }
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [hashtable]$spec) {
        $this.Registered++; $this.LastName = $name; $this.LastUser = $triggerUser
        $this.LastSpec = $spec
    }
    hidden [void] UnregisterTask([string]$name) { $this.Unregistered++; $this.LastName = $name }
    hidden [void] RemoveStaleTasks([string]$keepName) { $this.StaleSweeps++ }
}

# Exercises the real GetInteractiveUser against faked session probes: OwnerBySession
# maps a session id (or 'any') to that desktop's owner, and AskedSessions records order.
class SessionProbeService : StartupTaskService {
    [hashtable] $OwnerBySession = @{}
    [string] $ComputerSystemUser
    [System.Collections.Generic.List[object]] $AskedSessions

    SessionProbeService([LogService]$logger) : base($logger, $null, 'C:\App\src') {
        $this.AskedSessions = [System.Collections.Generic.List[object]]::new()
    }

    hidden [string] GetSessionOwner([object]$sessionId) {
        $this.AskedSessions.Add($sessionId)
        $key = if ($null -eq $sessionId) { 'any' } else { [string]$sessionId }
        if ($this.OwnerBySession.ContainsKey($key)) { return $this.OwnerBySession[$key] }
        return $null
    }
    hidden [string] GetComputerSystemUser() { return $this.ComputerSystemUser }
}

# Its register seam throws (simulates a non-elevated Register-ScheduledTask) so the
# test can assert Apply swallows it and logs instead of propagating.
class ThrowingStartupTaskService : StartupTaskService {
    [object] $Existing = $null
    ThrowingStartupTaskService([LogService]$logger, [string]$sourceRoot)
    : base($logger, $null, $sourceRoot) { }
    hidden [hashtable] GetProcessIdentity() { return @{ Name = 'PROD\jdoe'; IsSystem = $false; IsElevated = $true } }
    hidden [string] GetInteractiveUser() { return 'PROD\jdoe' }
    hidden [object] GetExistingTask([string]$name) { return $this.Existing }
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [hashtable]$spec) { throw "access denied (not elevated)" }
    hidden [void] RemoveStaleTasks([string]$keepName) { }
}

BeforeAll {
    # A fake existing task whose action matches (or differs from) a spec.
    function New-FakeTask([string]$execute, [string]$arguments, [string]$workingDirectory) {
        return [pscustomobject]@{
            Actions = @([pscustomobject]@{
                    Execute          = $execute
                    Arguments        = $arguments
                    WorkingDirectory = $workingDirectory
                })
        }
    }
}

Describe "StartupTaskService" {

    BeforeAll {
        $script:logger = [CapturingLogService]::new()
        $script:svc = [StartupTaskService]::new($script:logger, $null, 'C:\App\src')
    }

    Context "TaskNameFor" {
        It "Is per-user from the account leaf (DONUT-jdoe from PROD\jdoe)" {
            [StartupTaskService]::TaskNameFor('PROD\jdoe') | Should -Be 'DONUT-jdoe'
        }
        It "Passes a domainless account through unchanged" {
            [StartupTaskService]::TaskNameFor('jdoe') | Should -Be 'DONUT-jdoe'
        }
    }

    Context "ResolveOwner (whose logon fires the task)" {
        It "Names the signed-in console user, never the account DONUT runs as" {
            # Over-the-shoulder UAC once bound the trigger to jdoe-admin, so the task sat Ready.
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.ResolveOwner().User | Should -Be 'PROD\jdoe'
        }

        It "Reports no user when no one is signed in at the console" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.ConsoleUser = $null
            $fake.ResolveOwner().User | Should -BeNullOrEmpty
        }
    }

    Context "GetInteractiveUser (session-scoped resolution)" {
        BeforeAll {
            $script:ownSession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        }

        It "Prefers the owner of DONUT's OWN session (the UAC case)" {
            $probe = [SessionProbeService]::new([CapturingLogService]::new())
            $probe.OwnerBySession = @{ ([string]$script:ownSession) = 'PROD\jdoe' }
            $probe.ComputerSystemUser = 'PROD\wrong'
            $probe.GetInteractiveUser() | Should -Be 'PROD\jdoe'
            $probe.AskedSessions[0] | Should -Be $script:ownSession
        }

        It "Falls back to Win32_ComputerSystem when its own session has no desktop" {
            $probe = [SessionProbeService]::new([CapturingLogService]::new())
            $probe.ComputerSystemUser = 'PROD\jdoe'
            $probe.GetInteractiveUser() | Should -Be 'PROD\jdoe'
        }

        It "Falls back to any desktop owner when nothing else answers (session 0)" {
            $probe = [SessionProbeService]::new([CapturingLogService]::new())
            $probe.OwnerBySession = @{ 'any' = 'PROD\jdoe' }
            $probe.GetInteractiveUser() | Should -Be 'PROD\jdoe'
        }
    }

    Context "BuildLaunchSpec" {
        It "Uses -File ...Start-Donut.ps1 -Tray for a pwsh.exe host" {
            $spec = $script:svc.BuildLaunchSpec('C:\Program Files\PowerShell\7\pwsh.exe', 'C:\My App\src')
            $spec.Execute | Should -Be 'C:\Program Files\PowerShell\7\pwsh.exe'
            $spec.Argument | Should -Be '-Sta -ExecutionPolicy Bypass -File "C:\My App\src\Start-Donut.ps1" -Tray'
            # Without this Task Scheduler starts it in %windir%\system32.
            $spec.WorkingDirectory | Should -Be 'C:\My App\src'
        }

        # Split-Path uses the platform separator, so a Windows path only splits on Windows.
        It "Runs the packaged launcher from its own folder" -Skip:(-not $IsWindows) {
            $spec = $script:svc.BuildLaunchSpec('C:\Program Files\DONUT\Donut.Launcher.exe', 'C:\ignored')
            $spec.WorkingDirectory | Should -Be 'C:\Program Files\DONUT'
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
            $script:spec = @{ Execute = 'C:\pwsh.exe'; Argument = '--x'; WorkingDirectory = 'C:\src' }
            $script:matching = New-FakeTask 'C:\pwsh.exe' '--x' 'C:\src'
            $script:differing = New-FakeTask 'C:\old\pwsh.exe' '--x' 'C:\src'
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
        It "Reregisters a task that predates the working directory" {
            # Tasks predating WorkingDirectory carry a blank one and would launch from system32.
            $noWorkDir = New-FakeTask 'C:\pwsh.exe' '--x' ''
            $script:svc.ReconcileDecision($true, $noWorkDir, $script:spec) | Should -Be 'Reregister'
        }
        It "Treats a task with a differing argument as Reregister" {
            $argDiff = New-FakeTask 'C:\pwsh.exe' '--other' 'C:\src'
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

        It "Registers with the console account and its per-user task name" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.LastUser | Should -Be 'PROD\jdoe'
            $fake.LastName | Should -Be 'DONUT-jdoe'
        }

        It "Names and triggers the task for the console user when DONUT runs as a separate admin" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.LastName | Should -Be 'DONUT-jdoe' -Because 'DONUT-jdoe-admin would never fire'
            $fake.LastUser | Should -Be 'PROD\jdoe'
        }

        It "Sweeps stale differently-named tasks after applying" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.StaleSweeps | Should -Be 1
        }

        It "Fails with a reason (no throw) when no one is signed in at the console" {
            $logger = [CapturingLogService]::new()
            $fake = [FakeStartupTaskService]::new($logger, 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
            $fake.ConsoleUser = $null
            $fake.Apply($true) | Should -BeFalse
            $fake.Registered | Should -Be 0
            $fake.LastFailure | Should -BeLike '*console user*'
            $logger.HasLevel('ERROR') | Should -BeTrue
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

        It "Never throws to the caller when a seam fails, and keeps the reason" {
            $logger = [CapturingLogService]::new()
            $throwing = [ThrowingStartupTaskService]::new($logger, 'C:\App\src')
            $throwing.Existing = $null
            { $throwing.Apply($true) } | Should -Not -Throw
            $throwing.LastFailure | Should -BeLike '*access denied*'
            $logger.HasLevel('ERROR') | Should -BeTrue
        }
    }
}
