<#
.SYNOPSIS
    Runspace-pool worker that performs one remote operation on a target host.

.DESCRIPTION
    Invoked on the runspace pool for each queued AsyncJob. Rebuilds the AppConfig
    — preferring the live in-memory Settings passed from the UI, else config.json,
    else defaults — and hands off to ExecutionService.StartWorker, which asserts
    reachability on this pool thread and dispatches by job kind (scan / apply /
    inventory / disk / resolve).

.PARAMETER HostName
    Target machine to operate on.

.PARAMETER JobType
    Worker operation token: Scan / Apply / Inventory / DiskScan / Resolve.

.PARAMETER Options
    Per-job options (e.g. selected updates, TopN, the inventory probe script).

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

param(
    [string]$HostName,
    [string]$JobType,
    [hashtable]$Options,
    [string]$SourceRoot,
    [string]$LogsDir,
    [string]$ReportsDir,
    [hashtable]$Settings,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

try {
    # Prefer the live config object sent from the UI so the run reflects exactly
    # what the user configured. config.json is only persistence: fall back to it
    # (or to defaults) when no Settings were supplied.
    $config = if ($Settings) {
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, $Settings)
    } elseif ($ConfigPath -and (Test-Path $ConfigPath)) {
        $mgr = [ConfigManager]::new($SourceRoot)
        $mgr.LoadConfig()
    } else {
        # Use default config with provided paths
        [AppConfig]::new($SourceRoot, $LogsDir, $ReportsDir, @{})
    }
    
    [ExecutionService]::StartWorker($HostName, $JobType, $Options, $config, $SourceRoot, $LogsDir, $ReportsDir)
} catch {
    Write-Error "Worker failed: $_"
    exit 1
}
