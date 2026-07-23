<#
.SYNOPSIS
    Runspace-pool worker that performs one remote operation on a target host.

.DESCRIPTION
    Invoked on the runspace pool for each queued AsyncJob. Rebuilds the AppConfig
    — preferring the live in-memory Settings passed from the UI, else config.json,
    else defaults — and hands off to ExecutionService.StartWorker, which dispatches
    by job kind (scan / apply / inventory / disk / resolve); each phase gates its
    own transport (bounded RPC/SMB port probes) before touching the target.

.PARAMETER HostName
    Target machine to operate on.

.PARAMETER JobType
    Worker operation token: Scan / Apply / Inventory / DiskScan / Resolve.

.PARAMETER Options
    Per-job options (e.g. selected updates, TopN, the inventory probe script).

.PARAMETER ResolvedIp
    Pre-resolved target IP (from HostResolver) so the worker skips DNS on the hot
    path. A dedicated argument, NOT an Options key, so it can never reach a dcu-cli
    command line.

.PARAMETER SourceRoot
    The 'src' root, used to locate scripts and bundled tools.

.PARAMETER LogsDir
    Local logs directory; remote logs are copied here.

.PARAMETER ReportsDir
    Local reports directory; parsed reports are cached here.

.PARAMETER Settings
    Live config hashtable from the UI; takes precedence over config.json.

.PARAMETER ConfigPath
    Fallback config.json path, used only when no Settings are supplied.

.NOTES
    Runs on a pool runspace, never the WPF dispatcher.
#>
using module "..\Services\WorkerServices.psm1"
using module "..\Models\AppConfig.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\LogService.psm1"

param(
    [string]$HostName,
    [string]$JobType,
    [hashtable]$Options,
    [string]$ResolvedIp,
    [string]$SourceRoot,
    [string]$LogsDir,
    [string]$ReportsDir,
    [hashtable]$Settings,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

# First possible trace: execution only reaches here after the runspace finished
# parsing/compiling this script and its whole using-module graph, so the gap
# between the submitter's "Started X job." line and this one IS the queue +
# compile time. A job whose log shows "Started" but never this line either never
# got a runspace or is still (or forever) compiling.
$workerLog = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($LogsDir)) {
        $workerLog = [LogService]::new($LogsDir)
        $modeText = if ($Options -and $Options.Mode) { [string]$Options.Mode } else { '' }
        $workerLog.LogDebug(
            "[$HostName] Worker up: JobType=$JobType Mode=$modeText " +
            "(graph compiled, pipeline starting).")
    }
}
catch {
    Write-Warning "Worker start trace unavailable: $($_.Exception.Message)"
}

try {
    # Prefer the config snapshot sent from the UI (config.json is only persistence);
    # fall back to it, or to defaults, when no Settings were supplied. The source
    # breadcrumb splits the silent gap between "Worker up" and the worker service's
    # first line: if the log stops before "Config built", the wedge is inside the
    # config merge itself.
    $configSource = 'defaults'
    $config = if ($Settings) {
        $configSource = 'ui snapshot'
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, $Settings)
    }
    elseif ($ConfigPath -and (Test-Path $ConfigPath)) {
        $configSource = 'config file'
        $mgr = [ConfigManager]::new($SourceRoot)
        $mgr.LoadConfig()
    }
    else {
        # Use default config with provided paths
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, @{})
    }
    if ($null -ne $workerLog) {
        $workerLog.LogDebug("[$HostName] Config built ($configSource).")
    }

    [ExecutionService]::StartWorker($HostName, $JobType, $Options, $ResolvedIp,
        $config, $SourceRoot, $LogsDir, $ReportsDir)
}
catch {
    # The error stream reaches Donut.log only if the job's Poll() drains it; a
    # worker that dies while the pump is stalled would otherwise vanish, so the
    # failure is also written straight to the log file.
    if ($null -ne $workerLog) {
        $workerLog.LogException("[$HostName] $JobType worker failed", $_)
    }
    Write-Error "Worker failed: $_"
    exit 1
}
