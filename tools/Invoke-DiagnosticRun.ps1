#Requires -Version 7
<#
.SYNOPSIS
    Headless diagnostic run: warm barrier -> DC discovery -> resolve -> disk scan,
    with full evidence collection, bundled into one zip.

.DESCRIPTION
    Runs the app's startup pool sequence without the WPF UI, in a fresh child
    pwsh (mirroring production: the app is its own process), and collects every
    signal a wedge can leave:

      - verdict.json        per-phase completion + wall-clock (rewritten after
                            every phase, so a killed child still reports)
      - Donut.log           the harness run's own worker log (hermetic LogsDir)
      - provenance.json     commit/dirty, pwsh, OS, Defender/AMSI signature
                            versions + ages (the environmental-drift test)
      - events-*.csv        PowerShell script-block/module events + Defender
                            events for the run window (per-process -SettingsFile;
                            no machine policy is touched)
      - stacks.txt          runspace call stacks captured before killing a child
                            that blew its deadline (Get-DonutRunspaceStacks.ps1)
      - app-donut-tail.log  tail of the real app's machine-wide Donut.log

    Self-contained by design: it imports nothing from src/, so a fixed copy of
    this script can drive `git bisect run` against any checkout via -SourceRoot
    (see docs/development/testing.md, "Empirical bisect protocol").

.PARAMETER TargetHost
    Host for the resolve + disk phases. Empty (default) skips both.

.PARAMETER WarmCount
    Concurrent warm passes, matching the app's throttle. Default 8.

.PARAMETER SourceRoot
    The src\ folder of the checkout under test. Default: this repo's src.

.PARAMETER IncludeDiskScan
    Also run a real disk scan against -TargetHost (deploys WizTree there).

.PARAMETER PhaseTimeouts
    Override seconds per phase: @{ Warm=120; Dc=90; Host=90; Disk=180 }.

.PARAMETER OutDir
    Evidence directory. Default: $env:TEMP\DonutDiag-<timestamp>.

.PARAMETER SkipEventLog
    Skip the Windows event-log export (faster; use for bisect runs).

.PARAMETER BisectExitCodes
    git-bisect-run mapping: pass->0, symptom-fail->1, harness-broken->125.
    Default mapping: pass->0, harness-broken->1, symptom-fail->2.

.EXAMPLE
    pwsh -File tools\Invoke-DiagnosticRun.ps1 -TargetHost PC-042
    Full pipeline; hand over the zip it prints last.

.EXAMPLE
    git bisect run pwsh -NoProfile -File $env:TEMP\donut-harness\Invoke-DiagnosticRun.ps1 `
        -SourceRoot .\src -SkipEventLog -BisectExitCodes
#>
[CmdletBinding()]
param(
    [string]    $TargetHost = '',
    [int]       $WarmCount = 8,
    [string]    $SourceRoot = '',
    [switch]    $IncludeDiskScan,
    [hashtable] $PhaseTimeouts = @{},
    [string]    $OutDir = '',
    [switch]    $SkipEventLog,
    [switch]    $BisectExitCodes
)

$ErrorActionPreference = 'Stop'
$runStart = Get-Date

# --- Paths -------------------------------------------------------------------
if (-not $SourceRoot) {
    $SourceRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\src')).Path
}
$SourceRoot = (Resolve-Path $SourceRoot).Path
if (-not $OutDir) {
    $OutDir = Join-Path ([System.IO.Path]::GetTempPath()) `
    ("DonutDiag-" + $runStart.ToString('yyyyMMdd-HHmmss'))
}
$logsDir = Join-Path $OutDir 'logs'
$reportsDir = Join-Path $OutDir 'reports'
New-Item -ItemType Directory -Force -Path $OutDir, $logsDir, $reportsDir | Out-Null

$timeouts = @{ Warm = 120; Dc = 90; Host = 90; Disk = 180 }
foreach ($k in $PhaseTimeouts.Keys) { $timeouts[$k] = [int]$PhaseTimeouts[$k] }

function Write-Note([string]$message) {
    Write-Host "[diag] $message"
}

# --- Provenance (self-contained twin of src/Core/BuildProvenance.psm1) --------
$prov = [ordered]@{
    Commit          = 'unknown'
    Dirty           = $null
    SourceRoot      = $SourceRoot
    PwshVersion     = "$($PSVersionTable.PSVersion)"
    Os              = [System.Environment]::OSVersion.VersionString
    Machine         = [System.Environment]::MachineName
    User            = [System.Environment]::UserName
    RunStart        = $runStart.ToString('o')
    DefenderStatus  = $null
    ProvenanceNotes = @()
}
try {
    $repoRoot = Split-Path -Parent $SourceRoot
    if ((Test-Path (Join-Path $repoRoot '.git')) -and
        (Get-Command git -ErrorAction SilentlyContinue)) {
        $sha = & git -C $repoRoot rev-parse --short HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $sha) {
            $prov.Commit = "$sha".Trim()
            $prov.Dirty = @(& git -C $repoRoot status --porcelain 2>$null).Count -gt 0
        }
    }
} catch { $prov.ProvenanceNotes += "git probe failed: $($_.Exception.Message)" }
try {
    # Signature versions and ages are the direct test for "the machine changed, not the code".
    $mp = Get-MpComputerStatus -ErrorAction Stop
    $prov.DefenderStatus = [ordered]@{
        AMServiceVersion              = "$($mp.AMServiceVersion)"
        AntivirusSignatureVersion     = "$($mp.AntivirusSignatureVersion)"
        AntivirusSignatureLastUpdated = "$($mp.AntivirusSignatureLastUpdated)"
        RealTimeProtectionEnabled     = $mp.RealTimeProtectionEnabled
    }
} catch { $prov.ProvenanceNotes += "Get-MpComputerStatus unavailable: $($_.Exception.Message)" }
[pscustomobject]$prov | ConvertTo-Json -Depth 4 |
    Set-Content -Path (Join-Path $OutDir 'provenance.json')
Write-Note "provenance: commit=$($prov.Commit) dirty=$($prov.Dirty) machine=$($prov.Machine)"

# --- Per-process script-block/module logging (no machine policy changes) ------
$settingsFile = Join-Path $OutDir 'pwsh-diag-settings.json'
@{
    PowerShellPolicies = @{
        ScriptBlockLogging = @{ EnableScriptBlockLogging = $true }
        ModuleLogging      = @{ EnableModuleLogging = $true; ModuleNames = @('*') }
    }
} | ConvertTo-Json -Depth 4 | Set-Content -Path $settingsFile

# --- Child harness script ------------------------------------------------------

# Restricted to the worker arguments every checkout in the bisect range understands.
$childScript = Join-Path $OutDir 'DiagHarness.ps1'
@'
param(
    [string]$SourceRoot, [string]$LogsDir, [string]$ReportsDir, [string]$OutFile,
    [string]$PidFile, [int]$WarmCount, [string]$TargetHost, [int]$IncludeDiskScan,
    [int]$WarmTimeout, [int]$DcTimeout, [int]$HostTimeout, [int]$DiskTimeout
)
$verdict = [ordered]@{
    StartedAtUtc = [datetime]::UtcNow.ToString('o')
    Warm  = $null
    Dc    = $null
    Hosts = $null
    Disk  = $null
    Error = ''
    FinishedAtUtc = ''
}
function Save-Verdict {
    [pscustomobject]$verdict | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile
}
Set-Content -Path $PidFile -Value $PID
Save-Verdict
try {
    $worker = Join-Path (Join-Path $SourceRoot 'Scripts') 'RemoteWorker.ps1'
    # DebugLog forced on: the DEBUG breadcrumbs ARE what this harness collects.
    $common = @{ SourceRoot = $SourceRoot; LogsDir = $LogsDir; ReportsDir = $ReportsDir
                 DebugLog = $true }
    $pool = [runspacefactory]::CreateRunspacePool($WarmCount, $WarmCount)
    $pool.Open()

    function Invoke-PoolScript([hashtable]$params, [int]$timeoutSec) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddCommand($worker)
        foreach ($k in $params.Keys) { [void]$ps.AddParameter($k, $params[$k]) }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $handle = $ps.BeginInvoke()
        $completed = $handle.AsyncWaitHandle.WaitOne($timeoutSec * 1000)
        $output = $null
        $err = ''
        if ($completed) {
            try { $output = $ps.EndInvoke($handle) }
            catch { $err = $_.Exception.Message }
            $ps.Dispose()
        }
        # A lapsed shell is deliberately leaked: disposing a running pipeline
        # blocks - the exact production hang. It dies with this process.
        return @{ Completed = $completed; Output = $output; Error = $err
                  Ms = $sw.ElapsedMilliseconds }
    }

    # WARM: all shells submitted CONCURRENTLY, then one shared barrier deadline -
    # byte-for-byte the WarmPool recipe. Concurrency IS the experiment.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $shells = @(); $handles = @(); $perShell = @()
    for ($i = 1; $i -le $WarmCount; $i++) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddCommand($worker)
        $args2 = $common + @{ HostName = "warm-$i"; JobType = 'Resolve'
                              ResolvedIp = ''; Options = @{ Mode = 'WarmRunspace' } }
        foreach ($k in $args2.Keys) { [void]$ps.AddParameter($k, $args2[$k]) }
        $handles += , $ps.BeginInvoke()
        $shells += , $ps
    }
    $deadline = [datetime]::UtcNow.AddSeconds($WarmTimeout)
    $warmDone = 0; $warmErr = 0
    for ($i = 0; $i -lt $shells.Count; $i++) {
        $remaining = [int][Math]::Max(0,
            ($deadline - [datetime]::UtcNow).TotalMilliseconds)
        $ok = $handles[$i].AsyncWaitHandle.WaitOne($remaining)
        $entry = [ordered]@{ Tag = "warm-$($i + 1)"; Completed = $ok
                             Ms = $sw.ElapsedMilliseconds; Error = '' }
        if ($ok) {
            try {
                [void]$shells[$i].EndInvoke($handles[$i])
                if ($shells[$i].HadErrors) {
                    $warmErr++
                    $entry.Error = "$($shells[$i].Streams.Error[0])"
                }
                else { $warmDone++ }
            }
            catch { $warmErr++; $entry.Error = $_.Exception.Message }
            $shells[$i].Dispose()
        }
        $perShell += , $entry
    }
    $verdict.Warm = [ordered]@{ Submitted = $WarmCount; Completed = $warmDone
                                Errored = $warmErr; PhaseMs = $sw.ElapsedMilliseconds
                                PerShell = $perShell }
    Save-Verdict
    if (($warmDone + $warmErr) -lt $WarmCount) {
        # Wedged shells stay alive (leaked) until this process exits: flag the
        # parent to capture their stacks NOW, and hold a probe window open.
        Set-Content -Path (Join-Path (Split-Path $OutFile -Parent) 'wedge.flag') -Value $PID
        Start-Sleep -Seconds 25
    }

    # DC discovery (Mode=Warm): the one result every later resolve gates on.
    $dc = Invoke-PoolScript ($common + @{ HostName = ''; JobType = 'Resolve'
            ResolvedIp = ''; Options = @{ Mode = 'Warm' } }) $DcTimeout
    $activeDc = ''
    if ($dc.Completed -and @($dc.Output).Count -gt 0) {
        $activeDc = [string]@($dc.Output)[0].ActiveDc
    }
    $verdict.Dc = [ordered]@{ Ran = $true; Completed = $dc.Completed
                              ActiveDc = $activeDc; Ms = $dc.Ms; Error = $dc.Error }
    Save-Verdict

    # HOST RESOLVE (Mode=Host): the field symptom - only runs with a target.
    if ($TargetHost) {
        $res = Invoke-PoolScript ($common + @{ HostName = $TargetHost
                JobType = 'Resolve'; ResolvedIp = ''
                Options = @{ Mode = 'Host'; Dc = $activeDc } }) $HostTimeout
        $ip = ''; $online = $false
        if ($res.Completed -and @($res.Output).Count -gt 0) {
            $ip = [string]@($res.Output)[0].Ip
            $online = [bool]@($res.Output)[0].Online
        }
        $verdict.Hosts = [ordered]@{ Ran = $true; Completed = $res.Completed
                                     Ip = $ip; Online = $online; Ms = $res.Ms
                                     Error = $res.Error }
        Save-Verdict

        # DISK SCAN: end-to-end proof (WizTree deploy over SMB + PsExec run).
        if ($IncludeDiskScan -eq 1 -and $ip) {
            $disk = Invoke-PoolScript ($common + @{ HostName = $TargetHost
                    JobType = 'DiskScan'; ResolvedIp = $ip
                    Options = @{} }) $DiskTimeout
            $verdict.Disk = [ordered]@{ Ran = $true; Completed = $disk.Completed
                                        Ms = $disk.Ms; Error = $disk.Error }
            Save-Verdict
        }
    }
}
catch {
    $verdict.Error = $_.Exception.Message
    Save-Verdict
    [Environment]::Exit(1)
}
$verdict.FinishedAtUtc = [datetime]::UtcNow.ToString('o')
Save-Verdict
# Environment.Exit, not 'exit': leaked wedged pipelines are FOREGROUND threads
# and would otherwise keep this process alive until the parent's kill.
[Environment]::Exit(0)
'@ | Set-Content -Path $childScript

# --- Run the child under a bounded parent watchdog ----------------------------
$verdictFile = Join-Path $OutDir 'verdict.json'
$pidFile = Join-Path $OutDir 'child.pid'
$stacksFile = Join-Path $OutDir 'stacks.txt'
$pwshPath = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($pwshPath)) { $pwshPath = 'pwsh' }

$childArgs = @(
    '-NoProfile', '-SettingsFile', $settingsFile, '-File', $childScript,
    '-SourceRoot', $SourceRoot, '-LogsDir', $logsDir, '-ReportsDir', $reportsDir,
    '-OutFile', $verdictFile, '-PidFile', $pidFile,
    '-WarmCount', "$WarmCount",
    '-IncludeDiskScan', "$([int]$IncludeDiskScan.IsPresent)",
    '-WarmTimeout', "$($timeouts.Warm)", '-DcTimeout', "$($timeouts.Dc)",
    '-HostTimeout', "$($timeouts.Host)", '-DiskTimeout', "$($timeouts.Disk)"
)
if ($TargetHost) { $childArgs += @('-TargetHost', $TargetHost) }
Write-Note "child: $pwshPath (warm x$WarmCount, target='$TargetHost', disk=$($IncludeDiskScan.IsPresent))"

# ArgumentList quotes each argument: Start-Process's space-join mangles empty and spaced ones.
$psi = [System.Diagnostics.ProcessStartInfo]::new($pwshPath)
foreach ($a in $childArgs) { $psi.ArgumentList.Add([string]$a) }
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

function Invoke-StackProbe([int]$targetPid) {
    $probe = Join-Path $PSScriptRoot 'Get-DonutRunspaceStacks.ps1'
    try {
        & $pwshPath -NoProfile -File $probe -ProcessId $targetPid -OutFile $stacksFile |
            Out-Null
    } catch { Write-Note "stack probe failed: $($_.Exception.Message)" }
}

# Probe as soon as the child flags a barrier lapse, while the wedged shells are still alive.
$budgetSec = $timeouts.Warm + $timeouts.Dc + $timeouts.Host + $timeouts.Disk + 90
$watchDeadline = [datetime]::UtcNow.AddSeconds($budgetSec)
$wedgeFlag = Join-Path $OutDir 'wedge.flag'
$probed = $false
while (-not $proc.HasExited -and [datetime]::UtcNow -lt $watchDeadline) {
    if (-not $probed -and (Test-Path $wedgeFlag)) {
        $probed = $true
        Write-Note "barrier lapse flagged - capturing runspace stacks from the live child"
        Invoke-StackProbe $proc.Id
    }
    Start-Sleep -Milliseconds 500
}
$childTimedOut = -not $proc.HasExited
if ($childTimedOut) {
    # Stacks first, kill second: a dead process has no stacks left to read.
    Write-Note "child blew its ${budgetSec}s budget - capturing stacks before killing it"
    if (-not $probed) { Invoke-StackProbe $proc.Id }
    try { $proc.Kill($true) } catch { Write-Note "child kill failed: $($_.Exception.Message)" }
}

# --- Event export (Windows only; per-run time window) -------------------------
if (-not $SkipEventLog -and $IsWindows) {
    $psChannels = @('PowerShellCore/Operational', 'Microsoft-Windows-PowerShell/Operational')
    $found = $psChannels | Where-Object {
        Get-WinEvent -ListLog $_ -ErrorAction SilentlyContinue
    } | Select-Object -First 1
    if ($found) {
        try {
            Get-WinEvent -FilterHashtable @{ LogName = $found; StartTime = $runStart } `
                -ErrorAction Stop |
                Select-Object Id, TimeCreated, @{ n = 'Message'; e = {
                        $_.Message.Substring(0, [Math]::Min(600, $_.Message.Length)) } 
                } |
                Export-Csv -Path (Join-Path $OutDir 'events-powershell.csv') -NoTypeInformation
            Write-Note "exported PowerShell events from '$found'"
        } catch { Write-Note "PowerShell event export failed: $($_.Exception.Message)" }
    } else {
        Write-Note "no PowerShell operational channel registered (zip/Store install?) - skipped"
    }
    try {
        Get-WinEvent -FilterHashtable @{
            LogName   = 'Microsoft-Windows-Windows Defender/Operational'
            StartTime = $runStart 
        } -ErrorAction Stop |
            Select-Object Id, TimeCreated, @{ n = 'Message'; e = {
                    $_.Message.Substring(0, [Math]::Min(600, $_.Message.Length)) } 
            } |
            Export-Csv -Path (Join-Path $OutDir 'events-defender.csv') -NoTypeInformation
        Write-Note "exported Defender events"
    } catch { Write-Note "Defender event export skipped: $($_.Exception.Message)" }
}

# --- Cross-reference: the real app's log tail ---------------------------------
# The checkout's DonutPaths names the app log dir, loaded late to stay self-contained.
$appLog = ''
$donutPathsModule = Join-Path $SourceRoot 'Core\DonutPaths.psm1'
if (Test-Path $donutPathsModule) {
    $appLogsDir = & ([scriptblock]::Create(
            "using module '$donutPathsModule'`n[DonutPaths]::LogsDir()"))
    $appLog = Join-Path $appLogsDir 'Donut.log'
}
if ($appLog -and (Test-Path $appLog)) {
    Get-Content $appLog -Tail 2000 |
        Set-Content -Path (Join-Path $OutDir 'app-donut-tail.log')
}

# --- Verdict evaluation --------------------------------------------------------

# Broken means no verdict at all, symptom means an executed phase failed or timed out.
$verdict = if (Test-Path $verdictFile) {
    Get-Content $verdictFile -Raw | ConvertFrom-Json
} else { $null }

$outcome = 'pass'
if ($null -eq $verdict) { $outcome = 'broken' }
elseif ($childTimedOut) { $outcome = 'symptom' }
elseif ("$($verdict.Error)") { $outcome = 'symptom' }
elseif ($null -eq $verdict.Warm -or
    [int]$verdict.Warm.Completed -lt [int]$verdict.Warm.Submitted) { $outcome = 'symptom' }
elseif ($null -eq $verdict.Dc -or -not [bool]$verdict.Dc.Completed) { $outcome = 'symptom' }
elseif ($TargetHost -and ($null -eq $verdict.Hosts -or
        -not [bool]$verdict.Hosts.Completed -or -not "$($verdict.Hosts.Ip)")) {
    $outcome = 'symptom'
} elseif ($IncludeDiskScan -and $TargetHost -and ($null -eq $verdict.Disk -or
        -not [bool]$verdict.Disk.Completed)) {
    $outcome = 'symptom'
}
Write-Note "outcome: $outcome (timedOut=$childTimedOut)"
if ($null -ne $verdict -and $null -ne $verdict.Warm) {
    Write-Note ("warm: {0}/{1} completed, {2} errored, {3} ms" -f $verdict.Warm.Completed,
        $verdict.Warm.Submitted, $verdict.Warm.Errored, $verdict.Warm.PhaseMs)
}

# --- Bundle --------------------------------------------------------------------
$zipName = "DonutDiag-{0}-{1}-{2}.zip" -f [System.Environment]::MachineName,
    $prov.Commit, $runStart.ToString('yyyyMMdd-HHmmss')
$zipPath = Join-Path (Split-Path $OutDir -Parent) $zipName
try {
    Compress-Archive -Path (Join-Path $OutDir '*') -DestinationPath $zipPath -Force
} catch { Write-Note "bundle failed: $($_.Exception.Message)"; $zipPath = $OutDir }

# The zip path is the LAST line on purpose: CI and humans both consume it.
Write-Host $zipPath

if ($BisectExitCodes) {
    switch ($outcome) {
        'pass' { exit 0 }
        'symptom' { exit 1 }
        default { exit 125 }
    }
}
switch ($outcome) {
    'pass' { exit 0 }
    'broken' { exit 1 }
    default { exit 2 }
}
