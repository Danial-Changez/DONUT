<#
.SYNOPSIS
    Relaunches DONUT into the active console session via psexec. Runs as SYSTEM
    from the startup task's action, hosted by Windows PowerShell 5.1.

.DESCRIPTION
    psexec's -i flag WITHOUT a session id targets the CALLER's session, not the
    console session its documentation claims - and a SYSTEM scheduled task runs in
    session 0, so DONUT started on a desktop nobody can see (field-verified
    2026-07-27: task fired, psexec exited with the child PID, process in session
    0). Session ids change every logon, so the id cannot be baked into the task at
    register time; this shim resolves it at fire time and passes it explicitly.

.NOTES
    Progress and failures append to %ProgramData%\DONUT\logs\autostart.log - this
    runs before DONUT's own logger exists, and under SYSTEM %LOCALAPPDATA% is the
    system profile, so the machine-wide path is the one an operator can find.
#>
param(
    [Parameter(Mandatory)] [string]$PsExec,
    [Parameter(Mandatory)] [string]$Execute,
    [string]$ArgB64 = ''
)

$logDir = Join-Path $env:ProgramData 'DONUT\logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$script:LogFile = Join-Path $logDir 'autostart.log'

function Write-AutostartLog([string]$message) {
    Add-Content -Path $script:LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $message"
}

Add-Type -Namespace DonutNative -Name Wts -MemberDefinition `
    '[DllImport("kernel32.dll")] public static extern uint WTSGetActiveConsoleSessionId();'
$session = [DonutNative.Wts]::WTSGetActiveConsoleSessionId()
if ($session -eq [uint32]::MaxValue) {
    Write-AutostartLog "No active console session - DONUT not launched."
    exit 1
}

# The host arguments travel base64-encoded: they contain nested quotes (the dev
# pwsh case) that would not survive Task Scheduler -> powershell -File parsing.
$hostArgs = ''
if ($ArgB64) {
    $hostArgs = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ArgB64))
}

# One raw argument string, so the quoting built at register time reaches psexec verbatim.
$psexecArgs = "-accepteula -nobanner -s -i $session -d `"$Execute`" $hostArgs".TrimEnd()
Write-AutostartLog "Console session is $session; launching: psexec $psexecArgs"
$psexecRun = Start-Process -FilePath $PsExec -ArgumentList $psexecArgs `
    -WindowStyle Hidden -Wait -PassThru

# With -d, psexec's exit code IS the child PID on success; verify it points at a
# live process so a small Win32 error code can't masquerade as one.
$exitCode = $psexecRun.ExitCode
if ($exitCode -gt 0 -and (Get-Process -Id $exitCode -ErrorAction SilentlyContinue)) {
    Write-AutostartLog "psexec launched DONUT (pid $exitCode) in session $session."
    exit 0
}
Write-AutostartLog "psexec failed with exit code $exitCode."
exit 1
