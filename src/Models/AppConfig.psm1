class AppConfig {
    [string] $SourceRoot
    [string] $LogsPath
    [string] $ReportsPath
    [hashtable] $Settings

    # Default configuration structure
    # Reference: https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-update-cli-commands
    static [hashtable] $Defaults = @{
        activeCommand = 'scan'
        throttleLimit = 5
        commands = @{
            scan = @{
                args = @{
                    silent               = $false
                    report               = ''      # Path for XML report, e.g., 'C:\temp\DONUT'
                    outputLog            = ''      # Path for log file, e.g., 'C:\temp\DONUT\scan.log'
                    updateSeverity       = ''      # security,critical,recommended,optional
                    updateType           = ''      # bios,firmware,driver,application,others
                    updateDeviceCategory = ''      # audio,video,network,storage,input,chipset,others
                    catalogLocation      = ''      # Custom catalog path
                }
            }
            applyUpdates = @{
                args = @{
                    silent               = $false
                    reboot               = $false  # enable/disable - auto reboot after updates
                    autoSuspendBitLocker = $true   # enable/disable - suspend BitLocker for BIOS updates
                    forceupdate          = $false  # enable/disable - override pause during calls
                    outputLog            = ''      # Path for log file
                    updateSeverity       = ''      # security,critical,recommended,optional
                    updateType           = ''      # bios,firmware,driver,application,others
                    updateDeviceCategory = ''      # audio,video,network,storage,input,chipset,others
                    catalogLocation      = ''      # Custom catalog path
                }
            }
        }
    }

    AppConfig([string]$sourceRoot, [string]$logsPath, [string]$reportsPath, [hashtable]$settings) {
        $this.SourceRoot = $sourceRoot
        $this.LogsPath = $logsPath
        $this.ReportsPath = $reportsPath
        $this.Settings = $this.MergeWithDefaults($settings)
    }

    hidden [hashtable] MergeWithDefaults([hashtable]$userSettings) {
        if ($null -eq $userSettings) { return [AppConfig]::Defaults.Clone() }
        
        $merged = [AppConfig]::Defaults.Clone()
        foreach ($key in $userSettings.Keys) {
            if ($key -eq 'commands' -and $userSettings[$key] -is [hashtable]) {
                # Deep merge commands
                if (-not $merged.ContainsKey('commands')) { $merged['commands'] = @{} }
                foreach ($cmd in $userSettings[$key].Keys) {
                    if (-not $merged['commands'].ContainsKey($cmd)) {
                        $merged['commands'][$cmd] = $userSettings[$key][$cmd]
                    } elseif ($userSettings[$key][$cmd] -is [hashtable] -and $userSettings[$key][$cmd].ContainsKey('args')) {
                        # Merge args
                        foreach ($argKey in $userSettings[$key][$cmd]['args'].Keys) {
                            $merged['commands'][$cmd]['args'][$argKey] = $userSettings[$key][$cmd]['args'][$argKey]
                        }
                    }
                }
            } else {
                $merged[$key] = $userSettings[$key]
            }
        }
        return $merged
    }

    [object] GetSetting([string]$key, [object]$defaultValue) {
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey($key)) {
            return $this.Settings[$key]
        }
        return $defaultValue
    }

    [void] SetSetting([string]$key, [object]$value) {
        if ($null -eq $this.Settings) { $this.Settings = @{} }
        $this.Settings[$key] = $value
    }

    [string] GetActiveCommand() {
        # Modern: use 'activeCommand' field
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey('activeCommand')) {
            return $this.Settings['activeCommand']
        }
        return 'scan'
    }

    [void] SetActiveCommand([string]$command) {
        $this.SetSetting('activeCommand', $command)
    }

    [hashtable] GetCommandArgs([string]$command) {
        if ($null -ne $this.Settings -and 
            $this.Settings.ContainsKey('commands') -and 
            $this.Settings['commands'].ContainsKey($command) -and
            $this.Settings['commands'][$command].ContainsKey('args')) {
            return $this.Settings['commands'][$command]['args']
        }
        return @{}
    }

    [void] SetCommandArg([string]$command, [string]$argName, [object]$value) {
        if ($null -eq $this.Settings) { $this.Settings = @{} }
        if (-not $this.Settings.ContainsKey('commands')) { $this.Settings['commands'] = @{} }
        if (-not $this.Settings['commands'].ContainsKey($command)) { $this.Settings['commands'][$command] = @{ args = @{} } }
        if (-not $this.Settings['commands'][$command].ContainsKey('args')) { $this.Settings['commands'][$command]['args'] = @{} }
        $this.Settings['commands'][$command]['args'][$argName] = $value
    }

    [int] GetThrottleLimit() {
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey('throttleLimit')) {
            $val = $this.Settings['throttleLimit']
            if ($val -is [int]) { return $val }
            if ($val -is [string] -and $val -match '^\d+$') { return [int]$val }
        }
        return 5
    }

    [void] SetThrottleLimit([int]$limit) {
        $this.SetSetting('throttleLimit', $limit)
    }

    # Build DCU CLI argument string from command args
    # DCU CLI format: -option=value (not /option)
    [string] BuildDcuArgs([string]$command, [hashtable]$overrides) {
        $cmdArgs = $this.GetCommandArgs($command)
        
        # Apply any runtime overrides
        if ($null -ne $overrides) {
            foreach ($key in $overrides.Keys) {
                $cmdArgs[$key] = $overrides[$key]
            }
        }

        $argList = [System.Collections.ArrayList]::new()
        
        foreach ($key in $cmdArgs.Keys) {
            $val = $cmdArgs[$key]
            
            # Skip empty/null values
            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                continue
            }
            
            # Boolean flags use enable/disable format
            if ($val -is [bool]) {
                if ($val -eq $true) {
                    # Some flags are just present (like -silent), others need =enable
                    if ($key -in @('silent')) {
                        $argList.Add("-$key") | Out-Null
                    } else {
                        $argList.Add("-$key=enable") | Out-Null
                    }
                }
                # $false means don't include the flag (or use =disable if explicitly needed)
            }
            # String values with content
            elseif ($val -is [string]) {
                # Values with spaces need quotes
                if ($val -match '\s') {
                    $argList.Add("-$key=`"$val`"") | Out-Null
                } else {
                    $argList.Add("-$key=$val") | Out-Null
                }
            }
        }
        
        return $argList -join ' '
    }
}
