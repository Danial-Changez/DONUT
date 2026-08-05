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

    static hidden [string] $CachedPwsh

    # ProcessPath is pwsh only on the dev path. Launcher-hosted runs report the exe, and
    # spawning that forks a second DONUT the single-instance guard exits 0 (silent wedge).
    static [string] FindPwsh() {
        if (-not [string]::IsNullOrWhiteSpace([WorkerProcess]::CachedPwsh)) {
            return [WorkerProcess]::CachedPwsh
        }
        $path = [System.Environment]::ProcessPath
        if ([string]::IsNullOrWhiteSpace($path) -or
            (Split-Path $path -Leaf) -notin @('pwsh.exe', 'pwsh')) {
            $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
            $path = if ($cmd) { [string]$cmd.Source } else { '' }
        }
        [WorkerProcess]::CachedPwsh = $path
        return $path
    }

    # Serializes the worker args to a temp file (Options/Settings hashtables can't ride
    # a command line) and returns everything the pool runspace needs to launch the child.
    static [hashtable] Prepare([string]$scriptPath, [hashtable]$arguments, [string]$configPath) {
        $pwsh = [WorkerProcess]::FindPwsh()
        if ([string]::IsNullOrWhiteSpace($pwsh)) {
            throw "pwsh.exe was not found on PATH - worker processes cannot run without PowerShell 7."
        }

        $payload = @{} + $arguments
        if ($configPath) { $payload['ConfigPath'] = $configPath }

        $argsFile = [System.IO.Path]::GetTempFileName()
        $resultFile = [System.IO.Path]::GetTempFileName()
        ($payload | ConvertTo-Json -Depth 12) | Set-Content -LiteralPath $argsFile -Encoding UTF8

        return @{
            ArgsFile   = $argsFile
            ResultFile = $resultFile
            PwshPath   = $pwsh
            ScriptPath = $scriptPath
            Launcher   = [WorkerProcess]::Launcher
        }
    }

    # Runs on a pool runspace and streams the child's stdout into the Information stream.
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
        # Async stderr (a full pipe wedges the child), line-by-line stdout so progress lands live.
        $errTask = $proc.StandardError.ReadToEndAsync()
        while ($null -ne ($line = $proc.StandardOutput.ReadLine())) {
            Write-Information $line
        }
        $proc.WaitForExit()
        $err = $errTask.Result
        $result = $null
        if (Test-Path -LiteralPath $resultFile) {
            try { $result = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -AsHashtable }
            catch { $err += "`nResult parse failed: $($_.Exception.Message)" }
        }
        [pscustomobject]@{ Result = $result; ExitCode = $proc.ExitCode; StdErr = $err }
    }

    # Turns the launcher's return into a verdict: exit code 0 with no host errors is
    # success, otherwise the clean stderr line becomes the failure message.
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
            # Exit 0 with no result means the wrong child ran and the guard bowed out.
            if ($null -eq $launch.Result) {
                return @{ Result = $null; Succeeded = $false; ExitCode = 0
                    FailureMessage = 'Worker exited 0 but produced no result (was the wrong executable spawned as the worker?).'
                }
            }
            return @{ Result = $launch.Result; Succeeded = $true; ExitCode = 0; FailureMessage = '' }
        }
        $message = if ($stderr) { $stderr } else { "Worker exited with code $exit" }
        return @{ Result = $launch.Result; Succeeded = $false; ExitCode = $exit; FailureMessage = $message }
    }
}
