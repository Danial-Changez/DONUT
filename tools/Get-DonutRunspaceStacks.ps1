#Requires -Version 7
<#
.SYNOPSIS
    Dumps the script call stacks of every busy runspace in a live pwsh process.

.DESCRIPTION
    The answer to "the warm/resolve wedged - WHERE?". Attaches to the target
    process over PowerShell's built-in named-pipe IPC (same user, no tools to
    install), enumerates its runspaces, and for each Busy one requests a debugger
    break (Enable-RunspaceDebug -BreakAll), then prints the script call stack it
    breaks on.

    Interpreting the output:
      - A stack of frames         -> the runspace is executing script; the top
                                     frame is the statement it is spinning in.
      - "NO SCRIPT BREAK ..."     -> the pipeline never reached the next sequence
                                     point: it is wedged inside a single
                                     native/.NET call (hooked socket, AMSI scan,
                                     loader lock). That verdict is itself the
                                     diagnostic - the wedge is below PowerShell.
      - Attach timeout (exit 2)   -> the target's whole engine is unresponsive
                                     (e.g. a process-wide module-loader wedge);
                                     record that as the finding.

.PARAMETER ProcessId
    The pwsh process to probe. For the diagnostic harness this is the child it
    spawned; for the live app, the DONUT pwsh PID.

.PARAMETER TimeoutSec
    Bound for the attach AND for each per-runspace break wait. Default 15.

.PARAMETER OutFile
    Write the report here instead of stdout.

.NOTES
    Debugger breaks pause the runspace; Disable-RunspaceDebug (always run, in
    finally) releases any pending stop and resumes it. Pointing this at the live
    app mid-wedge is safe but pauses warm work for up to -TimeoutSec; prefer the
    Donut.log forensics first (barrier lapse lines carry per-shell state), then
    this probe, then 'dotnet-stack report -p <pid>' if native stacks are needed.

.EXAMPLE
    pwsh -File tools\Get-DonutRunspaceStacks.ps1 -ProcessId 12345
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [int] $ProcessId,
    [int]    $TimeoutSec = 15,
    [string] $OutFile = ''
)

$ErrorActionPreference = 'Stop'

# Runs INSIDE the target process. Engine/built-in commands only: pulling a module
# in a wedged process can hang on the very loader lock we came to observe.
$probeScript = {
    param([int]$BreakWaitSec)
    $lines = [System.Collections.Generic.List[string]]::new()
    $self = [runspace]::DefaultRunspace.Id
    foreach ($rs in Get-Runspace) {
        if ($rs.Id -eq $self) { continue }
        $lines.Add("Runspace Id=$($rs.Id) Name='$($rs.Name)' " +
            "State=$($rs.RunspaceStateInfo.State) " +
            "Availability=$($rs.RunspaceAvailability)")
        if ($rs.RunspaceAvailability -ne 'Busy') { continue }
        try {
            Enable-RunspaceDebug -Runspace $rs -BreakAll
            $deadline = [datetime]::UtcNow.AddSeconds($BreakWaitSec)
            while (-not $rs.Debugger.InBreakpoint -and
                [datetime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            if ($rs.Debugger.InBreakpoint) {
                foreach ($frame in $rs.Debugger.GetCallStack()) {
                    $lines.Add("    at $($frame.FunctionName) " +
                        "$($frame.ScriptName):$($frame.ScriptLineNumber)")
                }
            }
            else {
                $lines.Add("    NO SCRIPT BREAK within ${BreakWaitSec}s - pipeline " +
                    "is inside a single native/.NET call (hooked socket, AMSI " +
                    "scan, or loader lock; the wedge is below PowerShell).")
            }
        }
        catch {
            $lines.Add("    probe failed: $($_.Exception.Message)")
        }
        finally {
            try { Disable-RunspaceDebug -Runspace $rs }
            catch {
                $lines.Add("    WARNING: Disable-RunspaceDebug failed - the " +
                    "runspace may stay paused: $($_.Exception.Message)")
            }
        }
    }
    $lines
}

$report = [System.Collections.Generic.List[string]]::new()
$report.Add("=== Runspace stacks for PID $ProcessId " +
    "($([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))) ===")

$attachRunspace = $null
$shell = $null
$exitCode = 0
try {
    $ci = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($ProcessId)
    $ci.OpenTimeout = $TimeoutSec * 1000
    $attachRunspace = [runspacefactory]::CreateRunspace($ci)

    # Never a bare Open(): a dead pipe thread in the target must time out here,
    # not hang this probe too.
    $attachRunspace.OpenAsync()
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSec)
    while ($attachRunspace.RunspaceStateInfo.State -eq 'Opening' -and
        [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    if ($attachRunspace.RunspaceStateInfo.State -ne 'Opened') {
        $report.Add("ATTACH FAILED within ${TimeoutSec}s " +
            "(state: $($attachRunspace.RunspaceStateInfo.State)). The target's " +
            "engine is unresponsive - consistent with a process-wide loader wedge. " +
            "Fall back to the Donut.log barrier forensics or dotnet-stack.")
        $exitCode = 2
    }
    else {
        $shell = [powershell]::Create()
        $shell.Runspace = $attachRunspace
        [void]$shell.AddScript($probeScript.ToString()).AddArgument($TimeoutSec)
        $handle = $shell.BeginInvoke()

        # The probe waits up to TimeoutSec per busy runspace; pools run 8-16, so
        # bound the whole pass rather than guessing the busy count.
        $budgetMs = ($TimeoutSec * 18 + 30) * 1000
        if ($handle.AsyncWaitHandle.WaitOne($budgetMs)) {
            foreach ($line in $shell.EndInvoke($handle)) { $report.Add([string]$line) }
        }
        else {
            $report.Add("PROBE WEDGED inside the target (no reply in " +
                "$([int]($budgetMs / 1000))s) - even the attach session cannot " +
                "run script. That is a process-wide engine wedge; record it and " +
                "fall back to dotnet-stack for native stacks.")
            $exitCode = 2
        }
    }
}
catch {
    $report.Add("ATTACH FAILED: $($_.Exception.Message)")
    $exitCode = 2
}
finally {
    if ($null -ne $shell) { $shell.Dispose() }
    if ($null -ne $attachRunspace) { $attachRunspace.Dispose() }
}

if ($OutFile) {
    $report | Set-Content -Path $OutFile -Encoding UTF8
    Write-Host "Runspace stack report written to $OutFile"
}
else {
    $report | Write-Output
}
exit $exitCode
