<#
.SYNOPSIS
    Answers whether this process is elevated, and whether an action can run.

.DESCRIPTION
    DONUT used to guarantee elevation with a requireAdministrator manifest, so no
    call site ever asked. With the manifest on asInvoker the app can run as the
    standard console user, and remote work needs the operator's admin token: psexec
    and remote CIM both authenticate as the process. This is the one place that
    reads the token, plus the pure rule the UI gates on.

.NOTES
    Classify takes the elevation state as a parameter rather than reading it, so the
    decision is unit-testable off Windows; IsElevated is the only Win32 touch point
    and is deliberately trivial. Callers pass [ElevationContext]::IsElevated() in.
    Compare results against a named ElevationState member, never truthiness.
#>

# Whether a given action can proceed right now. RelaunchRequired is the only state
# that costs the user a UAC prompt, and only once: elevating restarts the whole UI.
enum ElevationState {
    NotRequired
    Satisfied
    RelaunchRequired
}

class ElevationContext {

    # True when the process token carries the Administrators group. Not the same as
    # IsSystem: a SYSTEM token is elevated, but not every elevated token is SYSTEM.
    static [bool] IsElevated() {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return ([System.Security.Principal.WindowsPrincipal]::new($identity)).IsInRole(
            [System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    # A service token, which is elevated but authenticates on the network as the
    # machine account - which is why autostart no longer runs DONUT this way.
    static [bool] IsSystem() {
        return [System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem
    }

    # The account the process runs as, e.g. DOMAIN\jdoe-admin under over-the-shoulder
    # UAC. Never the desktop's owner; StartupTaskService.GetInteractiveUser answers that.
    static [string] CurrentIdentityName() {
        return [string][System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }

    # Who owns the desktop DONUT shows on, never who DONUT runs as: under
    # over-the-shoulder UAC those differ. $null when there is no interactive session.
    static [string] InteractiveUser() {
        try {
            $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
            foreach ($filter in @("Name='explorer.exe' AND SessionId=$session", "Name='explorer.exe'")) {
                $explorer = Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if (-not $explorer) { continue }
                $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner -ErrorAction SilentlyContinue
                if ($owner -and $owner.User) { return "$($owner.Domain)\$($owner.User)" }
            }
            return $null
        }
        catch {
            # No CIM at all (a locked-down or non-Windows host). Callers treat a null as
            # "no interactive session", which is the same degraded path.
            return $null
        }
    }

    # The verdict the UI gates on: can this action run now, and if not, why not.
    static [ElevationState] Classify([bool]$actionNeedsAdmin, [bool]$isElevated) {
        if (-not $actionNeedsAdmin) { return [ElevationState]::NotRequired }
        if ($isElevated) { return [ElevationState]::Satisfied }
        return [ElevationState]::RelaunchRequired
    }

    # Convenience for call sites with nothing to fake: reads the token, then classifies.
    static [ElevationState] Classify([bool]$actionNeedsAdmin) {
        return [ElevationContext]::Classify($actionNeedsAdmin, [ElevationContext]::IsElevated())
    }
}
