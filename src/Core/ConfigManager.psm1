using module "..\Models\AppConfig.psm1"
using module ".\LogService.psm1"

<#
.SYNOPSIS
    Loads and saves DONUT's JSON config and ensures its data folders exist.

.DESCRIPTION
    Reads the bundled config under the source root plus the per-user override in
    %LOCALAPPDATA%\DONUT, deserializes config.json into an AppConfig, and persists
    changes back. Also guarantees the logs/reports directories exist.
#>
class ConfigManager {
    [string] $SourceRoot
    [string] $ConfigPath
    [string] $LogsPath
    [string] $ReportsPath
    [LogService] $Logger

    ConfigManager([string]$sourceRoot) {
        $this.Initialize($sourceRoot, $null)
    }

    ConfigManager([string]$sourceRoot, [LogService]$logger) {
        $this.Initialize($sourceRoot, $logger)
    }

    # Shared constructor body (PowerShell classes cannot chain to a sibling
    # constructor, so the common setup lives here).
    hidden [void] Initialize([string]$sourceRoot, [LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.SourceRoot = $sourceRoot

        $appDataRoot = Join-Path $env:LOCALAPPDATA "DONUT"
        $configDir = Join-Path $appDataRoot "config"

        $this.ConfigPath = Join-Path $configDir "config.json"
        $this.LogsPath = Join-Path $appDataRoot "logs"
        $this.ReportsPath = Join-Path $appDataRoot "reports"

        $this.EnsureDirectories()
    }

    [void] EnsureDirectories() {
        $configDir = Split-Path $this.ConfigPath -Parent
        foreach ($dir in @($configDir, $this.LogsPath, $this.ReportsPath)) {
            if (-not (Test-Path $dir)) {
                try {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    $this.Logger.LogDebug("Created directory: $dir")
                }
                catch {
                    $this.Logger.LogException("Failed to create directory '$dir'", $_)
                    throw
                }
            }
        }
    }

    [AppConfig] LoadConfig() {
        $settings = @{}
        if (Test-Path $this.ConfigPath) {
            try {
                $json = Get-Content -Path $this.ConfigPath -Raw
                $settings = $json | ConvertFrom-Json -AsHashtable
                $this.Logger.LogInfo("Loaded configuration from $($this.ConfigPath)")
            }
            catch {
                $this.Logger.LogException("Failed to load config from '$($this.ConfigPath)'; falling back to defaults", $_)
                $settings = @{}
            }
        }
        else {
            $this.Logger.LogInfo("No configuration found at $($this.ConfigPath); writing defaults.")
            $this.SaveConfig((New-Object AppConfig $this.SourceRoot, $this.LogsPath, $this.ReportsPath, @{}))
        }

        return (New-Object AppConfig $this.SourceRoot, $this.LogsPath, $this.ReportsPath, $settings)
    }

    [void] SaveConfig([AppConfig]$config) {
        try {
            $json = $config.Settings | ConvertTo-Json -Depth 10
            $json | Set-Content -Path $this.ConfigPath
            $this.Logger.LogDebug("Saved configuration to $($this.ConfigPath)")
        }
        catch {
            $this.Logger.LogException("Failed to save config to '$($this.ConfigPath)'", $_)
        }
    }
}
