using module "..\Models\AppConfig.psm1"
using module ".\DonutPaths.psm1"
using module ".\LogService.psm1"

<#
.SYNOPSIS
    Loads and saves DONUT's JSON config and ensures its data folders exist.

.DESCRIPTION
    Reads the bundled config under the source root plus the machine-wide override
    under %ProgramData%\DONUT\data, deserializes config.json into an AppConfig, and
    persists changes back. Also guarantees the logs/reports directories exist, and
    secures the root on the first elevated run so a de-elevated one can write it.
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

    # PowerShell classes cannot chain constructors, so the shared setup lives here.
    hidden [void] Initialize([string]$sourceRoot, [LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.SourceRoot = $sourceRoot

        $this.ConfigPath = Join-Path ([DonutPaths]::ConfigDir()) "config.json"
        $this.LogsPath = [DonutPaths]::LogsDir()
        $this.ReportsPath = [DonutPaths]::ReportsDir()

        $this.EnsureDirectories()
    }

    [void] EnsureDirectories() {
        $configDir = Split-Path $this.ConfigPath -Parent
        $fresh = -not (Test-Path ([DonutPaths]::DataRoot()))
        foreach ($dir in @($configDir, $this.LogsPath, $this.ReportsPath)) {
            if (-not (Test-Path $dir)) {
                try {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                    $this.Logger.LogDebug("Created directory: $dir")
                } catch {
                    $this.Logger.LogException("Failed to create directory '$dir'", $_)
                    throw
                }
            }
        }
        if ($fresh) { $this.SecureDataRoot() }
    }

    # Best-effort: needs elevation, and the de-elevated instance depends on the
    # elevated one having done it. A missing ACL surfaces as a write failure later.
    hidden [void] SecureDataRoot() {
        $root = [DonutPaths]::DataRoot()
        $reason = [DonutPaths]::Secure($root)
        if ($reason) { $this.Logger.LogWarning("Data root left with inherited permissions: $reason") }
        else {
            $this.Logger.LogInfo("Secured the data root for SYSTEM, Administrators and the interactive user: $root")
        }

        # The move off %LOCALAPPDATA% is manual, so say where the old data is.
        $legacy = [DonutPaths]::LegacyRoot()
        if ($legacy -and (Test-Path $legacy)) {
            $this.Logger.LogWarning("Starting with a fresh data root at $root - " +
                "earlier settings, logs and reports are still under $legacy.")
        }
    }

    [AppConfig] LoadConfig() {
        $settings = @{}
        if (Test-Path $this.ConfigPath) {
            try {
                $json = Get-Content -Path $this.ConfigPath -Raw
                $settings = $json | ConvertFrom-Json -AsHashtable
                $this.Logger.LogInfo("Loaded configuration from $($this.ConfigPath)")
            } catch {
                $this.Logger.LogException(
                    "Failed to load config from '$($this.ConfigPath)'; falling back to defaults", $_)
                $settings = @{}
            }
        } else {
            $this.Logger.LogInfo("No configuration found at $($this.ConfigPath); writing defaults.")
            $this.SaveConfig((New-Object AppConfig $this.SourceRoot, $this.LogsPath,
                    $this.ReportsPath, @{}))
        }

        return (New-Object AppConfig $this.SourceRoot, $this.LogsPath, $this.ReportsPath, $settings)
    }

    [void] SaveConfig([AppConfig]$config) {
        try {
            $json = $config.Settings | ConvertTo-Json -Depth 10
            $json | Set-Content -Path $this.ConfigPath
            $this.Logger.LogDebug("Saved configuration to $($this.ConfigPath)")
        } catch {
            $this.Logger.LogException("Failed to save config to '$($this.ConfigPath)'", $_)
        }
    }
}
