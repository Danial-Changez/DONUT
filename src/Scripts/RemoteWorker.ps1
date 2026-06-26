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
