<#
.SYNOPSIS
    Builds and spawns the elevated replacement for a de-elevated DONUT.

.DESCRIPTION
    The half of the relaunch that needs no window, so both callers can share it: the
    startup check in DonutApp.ps1, which runs before MainPresenter exists, and
    MainPresenter.SpawnElevated, which adds its own teardown afterwards.

    Two hosts, one shape. The packaged launcher hosts src\ itself and takes
    --await-pid; the dev path runs Start-Donut.ps1 under pwsh and takes -AwaitPid. The
    successor waits on that PID so it does not collide with the single-instance mutex,
    which is Local\ scoped and therefore per-session, not per-token.

.NOTES
    Spawn never throws and never touches config. A declined UAC prompt is a normal
    outcome the caller has to keep running after, and only the caller knows whether the
    setting behind the attempt should be reverted - a declined toggle and a declined
    startup elevation revert differently.

    Automatic variables are unreadable inside a PowerShell class method (rejected at
    class-compile time), so the current PID comes from Process.GetCurrentProcess().
#>
class ElevationRelaunch {

    # Which executable to relaunch and how to spell "wait for me to exit" for that host.
    static [hashtable] BuildSpec([string]$sourceRoot) {
        $proc = [System.Diagnostics.Process]::GetCurrentProcess()
        $hostPath = $proc.MainModule.FileName
        $ownPid = $proc.Id
        if ([IO.Path]::GetFileName($hostPath) -ieq 'pwsh.exe') {
            $script = Join-Path $sourceRoot 'Start-Donut.ps1'
            return @{
                FilePath  = $hostPath
                Arguments = "-NoProfile -Sta -ExecutionPolicy Bypass -File `"$script`" -AwaitPid $ownPid"
            }
        }
        return @{ FilePath = $hostPath; Arguments = "--await-pid $ownPid" }
    }

    # Returns Ok, Declined and Reason. Declined separates "the user said no" from "it
    # broke", which read the same to the caller but not to the person reading the toast.
    static [hashtable] Spawn([hashtable]$spec) {
        try {
            Start-Process -FilePath $spec.FilePath `
                          -ArgumentList $spec.Arguments `
                          -Verb RunAs `
                          -ErrorAction Stop
            return @{ Ok = $true; Declined = $false; Reason = '' }
        } catch {
            # 1223 is ERROR_CANCELLED: the consent or credential prompt was dismissed.
            $win32 = $_.Exception -as [System.ComponentModel.Win32Exception]
            $declined = $null -ne $win32 -and $win32.NativeErrorCode -eq 1223
            return @{ Ok = $false; Declined = $declined; Reason = $_.Exception.Message }
        }
    }
}
