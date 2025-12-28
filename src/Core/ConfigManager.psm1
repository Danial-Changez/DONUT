using module "..\Models\AppConfig.psm1"

class ConfigManager {
    [string] $SourceRoot
    [string] $ConfigPath
    [string] $LogsPath
    [string] $ReportsPath

    ConfigManager([string]$sourceRoot) {
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
        if (-not (Test-Path $configDir)) { New-Item -ItemType Directory -Path $configDir -Force | Out-Null }
        if (-not (Test-Path $this.LogsPath)) { New-Item -ItemType Directory -Path $this.LogsPath -Force | Out-Null }
        if (-not (Test-Path $this.ReportsPath)) { New-Item -ItemType Directory -Path $this.ReportsPath -Force | Out-Null }
    }

    [AppConfig] LoadConfig() {
        $settings = @{}
        if (Test-Path $this.ConfigPath) {
            try {
                $json = Get-Content -Path $this.ConfigPath -Raw
                $settings = $json | ConvertFrom-Json -AsHashtable
            }
            catch {
                Write-Error "Failed to load config: $_"
            }
        }
        else {
            # Initialize default settings if needed
            $this.SaveConfig((New-Object AppConfig $this.SourceRoot, $this.LogsPath, $this.ReportsPath, @{}))
        }

        return (New-Object AppConfig $this.SourceRoot, $this.LogsPath, $this.ReportsPath, $settings)
    }

    [void] SaveConfig([AppConfig]$config) {
        try {
            $json = $config.Settings | ConvertTo-Json -Depth 10
            $json | Set-Content -Path $this.ConfigPath
        }
        catch {
            Write-Error "Failed to save config: $_"
        }
    }
}
