<#
.SYNOPSIS
    Runs a worker script as an isolated child pwsh process and marshals its result.

.DESCRIPTION
    The one place that owns worker process-isolation. Each job runs in its own child
    process (separate AppDomain), so parallel workers never share the PowerShell
    class-load lock - the concurrency-safe model DONUT was originally built on. This
    module keeps that concern OUT of AsyncJob: Prepare() serializes the args and hands
    back the launcher; Launcher spawns the child on a pool runspace; Interpret() turns
    the child's exit code + result file into a verdict.

.NOTES
    The Launcher scriptblock deliberately uses NO `using module` / project classes -
    it must stay light so the pool runspace it runs on never compiles the class graph
    (that concurrent compile is the deadlock this whole design exists to avoid).
#>
class WorkerProcess {

    # Serializes the worker args to a temp file (Options/Settings hashtables can't ride
    # a command line) and returns everything the pool runspace needs to launch the child.
    static [hashtable] Prepare([string]$scriptPath, [hashtable]$arguments, [string]$configPath) {
        $payload = @{} + $arguments
        if ($configPath) { $payload['ConfigPath'] = $configPath }

        $argsFile = [System.IO.Path]::GetTempFileName()
        $resultFile = [System.IO.Path]::GetTempFileName()
        ($payload | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $argsFile -Encoding UTF8

        $pwsh = [System.Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($pwsh)) { $pwsh = 'pwsh' }

        return @{
            ArgsFile   = $argsFile
            ResultFile = $resultFile
            PwshPath   = $pwsh
            ScriptPath = $scriptPath
            Launcher   = [WorkerProcess]::Launcher
        }
    }

    # Runs ON a pool runspace (no using-module -> no class-load -> no deadlock): spawns
    # the worker as a child process and returns @{ Result; ExitCode; StdErr; StdOut }.
    static [scriptblock] $Launcher = {
        param($pwshPath, $scriptPath, $argsFile, $resultFile)
        $psi = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
        foreach ($a in @('-NoProfile', '-NoLogo', '-NonInteractive', '-File',
                $scriptPath, '-ArgsFile', $argsFile, '-ResultFile', $resultFile)) {
            $psi.ArgumentList.Add($a)
        }
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $err = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        $result = $null
        if (Test-Path -LiteralPath $resultFile) {
            try { $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -AsHashtable }
            catch { $err += "`nResult parse failed: $($_.Exception.Message)" }
        }
        [pscustomobject]@{ Result = $result; ExitCode = $proc.ExitCode; StdErr = $err; StdOut = $out }
    }

    # Turns the launcher's return into a verdict: exit code 0 (and no host errors) is
    # success; otherwise the clean stderr line is the failure message.
    static [hashtable] Interpret([object]$launcherOutput) {
        $launch = @($launcherOutput)[-1]
        if ($null -eq $launch) {
            return @{ Result = $null; Succeeded = $false; ExitCode = -1
                FailureMessage = 'Worker produced no result.'
            }
        }
        $exit = [int]$launch.ExitCode
        $stderr = "$($launch.StdErr)".Trim()
        if ($exit -eq 0) {
            return @{ Result = $launch.Result; Succeeded = $true; ExitCode = 0; FailureMessage = '' }
        }
        $message = if ($stderr) { $stderr } else { "Worker exited with code $exit" }
        return @{ Result = $launch.Result; Succeeded = $false; ExitCode = $exit; FailureMessage = $message }
    }
}
