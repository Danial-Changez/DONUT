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
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'

try {
    # Load config from the canonical %LOCALAPPDATA% location, or use defaults.
    # ConfigManager derives its own config path, so $ConfigPath only gates whether
    # a persisted config exists to load.
    $config = if ($ConfigPath -and (Test-Path $ConfigPath)) {
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
