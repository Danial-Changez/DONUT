using module "..\..\src\Services\StartupTaskService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Captures which CIM seam Apply dispatched to, without touching Task Scheduler.
#   Identity/ConsoleUser/PsExec: what the identity/psexec seams should report
#   Existing: the task GetExistingTask() should return (null = not installed)
#   Registered/Unregistered: how many times each seam ran
#   LastName/LastUser/LastAsSystem/LastSpec: what RegisterTask received
class FakeStartupTaskService : StartupTaskService {
    [hashtable] $Identity = @{ Name = 'PROD\jdoe'; IsSystem = $false }
    [string] $ConsoleUser = 'PROD\jdoe'
    [string] $PsExec = 'C:\App\src\Tools\psexec.exe'
    [object] $Existing = $null
    [int] $Registered = 0
    [int] $Unregistered = 0
    [string] $LastName
    [string] $LastUser
    [bool] $LastAsSystem
    [hashtable] $LastSpec

    FakeStartupTaskService([LogService]$logger, [string]$sourceRoot)
    : base($logger, $null, $sourceRoot) { }

    [int] $StaleSweeps = 0
    [int] $PointerSaves = 0

    hidden [hashtable] GetProcessIdentity() { return $this.Identity }
    hidden [string] GetInteractiveUser() { return $this.ConsoleUser }
    hidden [string] FindPsExec() { return $this.PsExec }
    hidden [object] GetExistingTask([string]$name) { return $this.Existing }
    hidden [void] SaveDataRootPointer() { $this.PointerSaves++ }
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [bool]$asSystem, [hashtable]$spec) {
        $this.Registered++; $this.LastName = $name; $this.LastUser = $triggerUser
        $this.LastAsSystem = $asSystem; $this.LastSpec = $spec
    }
    hidden [void] UnregisterTask([string]$name) { $this.Unregistered++; $this.LastName = $name }
    hidden [void] RemoveStaleTasks([string]$keepName) { $this.StaleSweeps++ }
}

# Exercises the REAL GetInteractiveUser against faked session probes: OwnerBySession
# maps a session id (or 'any') to that desktop's owner, AskedSessions records the order.
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
    hidden [hashtable] GetProcessIdentity() { return @{ Name = 'PROD\jdoe'; IsSystem = $false } }
    hidden [string] GetInteractiveUser() { return 'PROD\jdoe' }
    hidden [object] GetExistingTask([string]$name) { return $this.Existing }
    hidden [void] RegisterTask([string]$name, [string]$triggerUser, [bool]$asSystem, [hashtable]$spec) { throw "access denied (not elevated)" }
    hidden [void] RemoveStaleTasks([string]$keepName) { }
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

    Context "TaskNameFor" {
        It "Is per-user from the account leaf (DONUT-<username>)" {
            [StartupTaskService]::TaskNameFor('PROD\jdoe') | Should -Be 'DONUT-jdoe'
        }
        It "Passes a domainless account through unchanged" {
            [StartupTaskService]::TaskNameFor('jdoe') | Should -Be 'DONUT-jdoe'
        }
    }

    Context "ResolveOwner (trigger user vs run-as lane)" {
        It "Uses the per-user lane when DONUT already runs as the console user" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $owner = $fake.ResolveOwner()
            $owner.User | Should -Be 'PROD\jdoe'
            $owner.IsSystem | Should -BeFalse
        }

        It "Triggers on the CONSOLE user, not the admin account DONUT runs as" {
            # The regression: over-the-shoulder UAC (signed in as jdoe, DONUT elevated
            # as jdoe-admin in the SAME session) bound the trigger to jdoe-admin, an
            # account that never signs in - so the task sat Ready forever.
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $owner = $fake.ResolveOwner()
            $owner.User | Should -Be 'PROD\jdoe'
            $owner.IsSystem | Should -BeTrue -Because (
                'a separate admin account has no logon session of its own to host an interactive task')
        }

        It "Matches the console user case-insensitively" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\JDoe'; IsSystem = $false }
            $fake.ConsoleUser = 'prod\jdoe'
            $fake.ResolveOwner().IsSystem | Should -BeFalse
        }

        It "Uses the SYSTEM lane, triggered by the console user, under a SYSTEM token" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
            $fake.ConsoleUser = 'PROD\jdoe'
            $owner = $fake.ResolveOwner()
            $owner.User | Should -Be 'PROD\jdoe'
            $owner.IsSystem | Should -BeTrue
        }

        It "Reports no user when no one is signed in at the console" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
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

    Context "BuildSystemSpec" {
        It "Runs the shim under Windows PowerShell, quoting shim/psexec/host paths" {
            $spec = [StartupTaskService]::BuildSystemSpec('C:\App\src\Tools\psexec.exe',
                'C:\App\src\Scripts\Start-DonutInConsoleSession.ps1',
                @{ Execute = 'C:\Program Files\DONUT\Donut.Launcher.exe'; Argument = '--tray' })
            $spec.Execute | Should -BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
            $spec.Argument | Should -BeLike '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden *'
            $spec.Argument | Should -BeLike '*-File "C:\App\src\Scripts\Start-DonutInConsoleSession.ps1"*'
            $spec.Argument | Should -BeLike '*-PsExec "C:\App\src\Tools\psexec.exe"*'
            $spec.Argument | Should -BeLike '*-Execute "C:\Program Files\DONUT\Donut.Launcher.exe"*'
        }

        # psexec -i without a session id targets the CALLER's session (0 under a SYSTEM
        # task) - the shim exists to resolve the console session at fire time instead.
        It "Never bakes psexec -i into the action itself" {
            $spec = [StartupTaskService]::BuildSystemSpec('C:\pe.exe', 'C:\shim.ps1',
                @{ Execute = 'C:\d.exe'; Argument = '--tray' })
            $spec.Execute | Should -Not -Be 'C:\pe.exe'
            $spec.Argument | Should -Not -BeLike '*-accepteula*'
        }

        It "Base64-encodes the host arguments so nested quotes survive the task action" {
            $hostArgs = '-Sta -ExecutionPolicy Bypass -File "C:\My App\src\Start-Donut.ps1" -Tray'
            $spec = [StartupTaskService]::BuildSystemSpec('C:\pe.exe', 'C:\shim.ps1',
                @{ Execute = 'C:\pwsh.exe'; Argument = $hostArgs })
            $spec.Argument -match '-ArgB64 (\S+)$' | Should -BeTrue
            [System.Text.Encoding]::UTF8.GetString(
                [Convert]::FromBase64String($Matches[1])) | Should -Be $hostArgs
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

        It "Registers with the console account and its per-user task name" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.LastUser | Should -Be 'PROD\jdoe'
            $fake.LastName | Should -Be 'DONUT-jdoe'
            $fake.LastAsSystem | Should -BeFalse
        }

        It "Names and triggers the task for the console user when DONUT runs as a separate admin" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.LastName | Should -Be 'DONUT-jdoe' -Because 'DONUT-jdoe-admin would never fire'
            $fake.LastUser | Should -Be 'PROD\jdoe'
            $fake.LastAsSystem | Should -BeTrue
        }

        It "Sweeps stale differently-named tasks after applying" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.StaleSweeps | Should -Be 1
        }

        It "Registers the SYSTEM psexec lane when the token is SYSTEM" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.LastUser | Should -Be 'PROD\jdoe'
            $fake.LastName | Should -Be 'DONUT-jdoe'
            $fake.LastAsSystem | Should -BeTrue
            $fake.LastSpec.Execute | Should -BeLike '*\powershell.exe'
            $fake.LastSpec.Argument | Should -BeLike '*Start-DonutInConsoleSession.ps1*'
            $fake.LastSpec.Argument | Should -BeLike '*-PsExec "C:\App\src\Tools\psexec.exe"*'
        }

        # The settings live under whoever toggled autostart on (the admin-elevated
        # instance); the pointer is what routes the SYSTEM instance to that profile.
        It "Pins the settings home when an admin-elevated instance applies the SYSTEM lane" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.PointerSaves | Should -Be 1
        }

        It "Does not pin the settings home from a SYSTEM instance (its redirected env is not the source of truth)" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.Apply($true) | Should -BeTrue
            $fake.PointerSaves | Should -Be 0
        }

        It "Does not pin the settings home on the per-user lane or when disabling" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Apply($true) | Should -BeTrue
            $fake.PointerSaves | Should -Be 0
            $fake.Identity = @{ Name = 'PROD\jdoe-admin'; IsSystem = $false }
            $fake.Apply($false) | Should -BeTrue
            $fake.PointerSaves | Should -Be 0
        }

        It "Fails with a psexec reason when SYSTEM and psexec is missing" {
            $fake = [FakeStartupTaskService]::new([CapturingLogService]::new(), 'C:\App\src')
            $fake.Identity = @{ Name = 'NT AUTHORITY\SYSTEM'; IsSystem = $true }
            $fake.ConsoleUser = 'PROD\jdoe'
            $fake.PsExec = $null
            $fake.Apply($true) | Should -BeFalse
            $fake.Registered | Should -Be 0
            $fake.LastFailure | Should -BeLike '*psexec*'
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
