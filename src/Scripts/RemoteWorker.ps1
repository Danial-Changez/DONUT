<#
.SYNOPSIS
    Runspace-pool worker that performs one remote operation on a target host.

.DESCRIPTION
    Invoked on the runspace pool for each queued AsyncJob. Rebuilds the AppConfig
    - preferring the live in-memory Settings passed from the UI, else config.json,
    else defaults - and hands off to ExecutionService.StartWorker, which dispatches
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
    path. A dedicated argument rather than an Options key, so it can never reach a dcu-cli
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
    [string]$ConfigPath,
    # Parent's effective debug-log state (setting or session override), gating [DEBUG].
    [bool]$DebugLog,
    # Options and Settings cannot cross a command line, so args ride in a JSON file.
    [string]$ArgsFile,
    [string]$ResultFile
)

$ErrorActionPreference = 'Stop'
# Surfaces the live dcu tail lines on stdout so the parent can stream them to the UI.
$InformationPreference = 'Continue'

if ($ArgsFile) {
    $a = Get-Content -LiteralPath $ArgsFile -Raw | ConvertFrom-Json -AsHashtable
    $HostName = [string]$a.HostName
    $JobType = [string]$a.JobType
    $Options = if ($null -ne $a.Options) { [hashtable]$a.Options } else { @{} }
    $ResolvedIp = [string]$a.ResolvedIp
    $SourceRoot = [string]$a.SourceRoot
    $LogsDir = [string]$a.LogsDir
    $ReportsDir = [string]$a.ReportsDir
    $Settings = if ($null -ne $a.Settings) { [hashtable]$a.Settings } else { $null }
    if ($a.ContainsKey('ConfigPath')) { $ConfigPath = [string]$a.ConfigPath }
    if ($a.ContainsKey('DebugLog')) { $DebugLog = [bool]$a.DebugLog }
}

# The service graph gates debug from Config, so the session override must land there.
if ($null -ne $Settings) { $Settings['debugLogging'] = [bool]$DebugLog }

# First possible trace: "Started" with no "Worker up" means no runspace or a stuck compile.
$workerLog = $null
try {
    if (-not [string]::IsNullOrWhiteSpace($LogsDir)) {
        $workerLog = [LogService]::new($LogsDir)
        $workerLog.DebugEnabled = [bool]$DebugLog
        $modeText = if ($Options -and $Options.Mode) { [string]$Options.Mode } else { '' }
        $workerLog.LogDebug(
            "[$HostName] Worker up: JobType=$JobType Mode=$modeText " +
            "(graph compiled, pipeline starting).")
    }
} catch {
    Write-Warning "Worker start trace unavailable: $($_.Exception.Message)"
}

try {
    # The source breadcrumb pins a wedge before "Config built" to the config merge itself.
    $configSource = 'defaults'
    $config = if ($Settings) {
        $configSource = 'ui snapshot'
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, $Settings)
    } elseif ($ConfigPath -and (Test-Path $ConfigPath)) {
        $configSource = 'config file'
        $mgr = [ConfigManager]::new($SourceRoot)
        $mgr.LoadConfig()
    } else {
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, @{})
    }
    if ($null -ne $workerLog) {
        $workerLog.LogDebug("[$HostName] Config built ($configSource).")
    }

    $workerResult = [ExecutionService]::StartWorker($HostName, $JobType, $Options,
        $ResolvedIp, $config, $SourceRoot, $LogsDir, $ReportsDir)

    # Child processes take the result through the file, in-process callers off the pipeline.
    if ($ResultFile) {
        ($workerResult | ConvertTo-Json -Depth 12) |
            Set-Content -LiteralPath $ResultFile -Encoding UTF8
    } else {
        $workerResult
    }
} catch {
    # One clean stderr line, so RemoteFailure.ReasonFromMessage can still parse it.
    if ($null -ne $workerLog) {
        $workerLog.LogException("[$HostName] $JobType worker failed", $_)
    }
    [Console]::Error.WriteLine("Worker failed: $($_.Exception.Message)")
    exit 1
}
