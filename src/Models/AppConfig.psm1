<#
.SYNOPSIS
    Strongly-typed configuration container for DONUT.

.DESCRIPTION
    Holds the resolved source/logs/reports paths and the user Settings hashtable,
    merged over a static Defaults table (active command, throttle limit, AD
    forests, per-command DCU options). Builds the dcu-cli argument string for a
    command from its configured options, and round-trips through ConfigManager's
    JSON load/save.
#>
class AppConfig {
    [string] $SourceRoot
    [string] $LogsPath
    [string] $ReportsPath
    [hashtable] $Settings

    # DCU option reference:
    # https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-update-cli-commands
    static [hashtable] $Defaults = @{
        activeCommand         = 'scan'
        throttleLimit         = 8
        # Largest folders the on-demand storage scan returns (top-N by size).
        folderScanCount       = 12
        # How long a run keeps trying to reconnect + resume after a network drop (either
        # side) before it settles as Unconfirmed. See ExecutionService.RecoverByResumeTail.
        recoveryWindowMinutes = 30
        # AD forests searched by the Home live-finder (separate forests; each is
        # queried independently). Editable; these are the org defaults.
        domains               = @('prod.contoso.com', 'forest-b.contosogroup.com', 'forest-c.local', 'forest-d.local')
        # SCCM AdminService host (SMS Provider) for the user Lens's device lookup.
        adminServiceHost      = 'sccm01.contoso.com'
        # Start elevated at logon (scheduled task), hide the X into the tray, and the
        # global show/restore hotkey. All opt-in; blank hotkey disables it.
        startWithWindows      = $false
        closeToTray           = $false
        globalHotkey          = 'Ctrl+Alt+D'
        # Run elevated. On by default because remote work authenticates as the process:
        # de-elevated, DONUT is the console user, who has no rights on fleet targets.
        runAsAdmin            = $true
        # In-app shortcut (only while DONUT is focused) to open Settings; blank disables.
        openSettingsShortcut  = 'Ctrl+,'
        # Set once the first-run guided tour is shown/skipped; the ? button replays it.
        hasSeenTour           = $false
        # Verbose [DEBUG] breadcrumbs in Donut.log (Start-Donut -DebugLog overrides per session).
        debugLogging          = $false
        commands              = @{
            scan         = @{
                args = @{
                    silent               = $false
                    report               = ''      # Path for XML report, e.g., 'C:\temp\DONUT'
                    outputLog            = ''      # log file path, e.g. C:\temp\DONUT\scan.log
                    updateSeverity       = ''      # security,critical,recommended,optional
                    updateType           = ''      # bios,firmware,driver,application,others
                    updateDeviceCategory = ''      # audio,video,network,storage,input,chipset,others
                    catalogLocation      = ''      # custom catalog path
                }
            }
            applyUpdates = @{
                args = @{
                    silent               = $false
                    reboot               = $false  # auto reboot after updates
                    autoSuspendBitLocker = $true   # suspend BitLocker for BIOS updates
                    forceupdate          = $false  # override pause during calls
                    outputLog            = ''      # log file path
                    updateSeverity       = ''      # security,critical,recommended,optional
                    updateType           = ''      # bios,firmware,driver,application,others
                    updateDeviceCategory = ''      # audio,video,network,storage,input,chipset,others
                    catalogLocation      = ''      # custom catalog path
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
        # Deep clone so the shared static Defaults are never mutated and the result never
        # aliases the caller's hashtables (safe to re-merge an already-merged config).
        $merged = [AppConfig]::DeepClone([AppConfig]::Defaults)
        if ($null -eq $userSettings) { return $merged }

        foreach ($key in @($userSettings.Keys)) {
            if ($key -eq 'commands' -and $userSettings[$key] -is [hashtable]) {
                if (-not $merged.ContainsKey('commands')) { $merged['commands'] = @{} }
                foreach ($cmd in @($userSettings[$key].Keys)) {
                    $userCmd = $userSettings[$key][$cmd]
                    if (-not $merged['commands'].ContainsKey($cmd)) {
                        if ($userCmd -is [hashtable]) {
                            $merged['commands'][$cmd] = [AppConfig]::DeepClone($userCmd)
                        }
                        else {
                            $merged['commands'][$cmd] = $userCmd
                        }
                    }
                    elseif ($userCmd -is [hashtable] -and $userCmd.ContainsKey('args') -and
                        $userCmd['args'] -is [hashtable]) {
                        # Snapshot the keys - never enumerate a collection being written to.
                        foreach ($argKey in @($userCmd['args'].Keys)) {
                            $merged['commands'][$cmd]['args'][$argKey] = $userCmd['args'][$argKey]
                        }
                    }
                }
            }
            else {
                $merged[$key] = $userSettings[$key]
            }
        }
        return $merged
    }

    # Recursive by-value clone sharing no mutable structure with the source.
    # Cycle-safe: a self-containing table maps to its own clone, never recursing away.
    hidden static [hashtable] DeepClone([hashtable]$source) {
        $seen = [System.Collections.Generic.Dictionary[object, object]]::new(
            [System.Collections.Generic.ReferenceEqualityComparer]::Instance)
        return [AppConfig]::DeepCloneCore($source, $seen)
    }

    hidden static [hashtable] DeepCloneCore(
        [hashtable]$source,
        [System.Collections.Generic.Dictionary[object, object]]$seen
    ) {
        if ($seen.ContainsKey($source)) { return [hashtable]$seen[$source] }
        $copy = @{}
        $seen[$source] = $copy
        foreach ($k in @($source.Keys)) {
            $v = $source[$k]
            if ($v -is [hashtable]) {
                $copy[$k] = [AppConfig]::DeepCloneCore($v, $seen)
            }
            else {
                $copy[$k] = $v
            }
        }
        return $copy
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

    # AD forests for the Home live-finder. Tolerates the JSON round-trip
    # (Object[]/strings) and falls back to the org defaults when absent/blank.
    [string[]] GetDomains() {
        $val = $this.GetSetting('domains', $null)
        if ($val -is [System.Collections.IEnumerable] -and $val -isnot [string]) {
            $list = @($val | ForEach-Object { [string]$_ } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($list.Count -gt 0) { return $list }
        }
        return @('prod.contoso.com', 'forest-b.contosogroup.com', 'forest-c.local', 'forest-d.local')
    }

    # SCCM AdminService host for the user Lens device lookup. Falls back to the org default.
    [string] GetAdminServiceHost() {
        $val = [string]$this.GetSetting('adminServiceHost', $null)
        if (-not [string]::IsNullOrWhiteSpace($val)) { return $val.Trim() }
        return 'sccm01.contoso.com'
    }

    [int] GetThrottleLimit() {
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey('throttleLimit')) {
            $val = $this.Settings['throttleLimit']
            if ($val -is [int]) { return $val }
            if ($val -is [string] -and $val -match '^\d+$') { return [int]$val }
        }
        return 8
    }

    [void] SetThrottleLimit([int]$limit) {
        $this.SetSetting('throttleLimit', $limit)
    }

    [int] GetFolderScanCount() {
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey('folderScanCount')) {
            $val = $this.Settings['folderScanCount']
            if ($val -is [int]) { return $val }
            if ($val -is [string] -and $val -match '^\d+$') { return [int]$val }
        }
        return 12
    }

    [void] SetFolderScanCount([int]$count) {
        $this.SetSetting('folderScanCount', $count)
    }

    # Minutes a dropped run keeps reconnecting + resuming before settling Unconfirmed.
    # Clamped to >= 1 so a bad/zero config can't disable recovery outright.
    [int] GetRecoveryWindowMinutes() {
        $val = 30
        if ($null -ne $this.Settings -and $this.Settings.ContainsKey('recoveryWindowMinutes')) {
            $raw = $this.Settings['recoveryWindowMinutes']
            if ($raw -is [int]) { $val = $raw }
            elseif ($raw -is [string] -and $raw -match '^\d+$') { $val = [int]$raw }
        }
        if ($val -lt 1) { return 1 }
        return $val
    }

    # Start DONUT elevated at logon via a scheduled task. Tolerates JSON's string
    # booleans ('true'/'false') the same way GetThrottleLimit tolerates string ints.
    [bool] GetStartWithWindows() {
        return [AppConfig]::AsBool($this.GetSetting('startWithWindows', $null), $false)
    }

    # Hide the window into the tray on X instead of exiting. String-bool tolerant.
    [bool] GetCloseToTray() {
        return [AppConfig]::AsBool($this.GetSetting('closeToTray', $null), $false)
    }

    # Whether the first-run guided tour has already been shown (or skipped).
    [bool] GetHasSeenTour() {
        return [AppConfig]::AsBool($this.GetSetting('hasSeenTour', $null), $false)
    }

    # Verbose [DEBUG] logging (off by default; INFO/WARN/ERROR always flow). String-bool tolerant.
    [bool] GetDebugLogging() {
        return [AppConfig]::AsBool($this.GetSetting('debugLogging', $null), $false)
    }

    # Defaults to TRUE, unlike every other toggle here: a corrupt value must not silently
    # drop DONUT into a mode where no remote job can run. Intent only, not the live token.
    [bool] GetRunAsAdmin() {
        return [AppConfig]::AsBool($this.GetSetting('runAsAdmin', $null), $true)
    }

    # Global show/restore hotkey gesture (e.g. 'Ctrl+Alt+D'). Blank/whitespace
    # means the feature is disabled; returns '' in that case.
    [string] GetGlobalHotkey() {
        $val = [string]$this.GetSetting('globalHotkey', $null)
        if ([string]::IsNullOrWhiteSpace($val)) { return '' }
        return $val.Trim()
    }

    # In-app Open-Settings shortcut gesture (e.g. 'Ctrl+,'). Blank/whitespace disables it.
    [string] GetOpenSettingsShortcut() {
        $val = [string]$this.GetSetting('openSettingsShortcut', $null)
        if ([string]::IsNullOrWhiteSpace($val)) { return '' }
        return $val.Trim()
    }

    # Coerces a config value to bool: real [bool] as-is, 'true'/'false' (any case,
    # trimmed - TryParse's own contract) by parse, everything else to the default.
    hidden static [bool] AsBool([object]$value, [bool]$default) {
        if ($value -is [bool]) { return $value }
        $parsed = $false
        if ($value -is [string] -and [bool]::TryParse($value, [ref]$parsed)) { return $parsed }
        return $default
    }

    # Builds the dcu-cli argument string; DCU's format is -option=value (not /option).
    [string] BuildDcuArgs([string]$command, [hashtable]$overrides) {
        $cmdArgs = $this.GetCommandArgs($command)

        if ($null -ne $overrides) {
            foreach ($key in $overrides.Keys) {
                $cmdArgs[$key] = $overrides[$key]
            }
        }

        $argList = [System.Collections.ArrayList]::new()

        foreach ($key in $cmdArgs.Keys) {
            $val = $cmdArgs[$key]

            if ($null -eq $val -or ($val -is [string] -and [string]::IsNullOrWhiteSpace($val))) {
                continue
            }

            # Boolean flags use enable/disable format
            if ($val -is [bool]) {
                if ($val -eq $true) {
                    # Some flags are just present (like -silent), others need =enable
                    if ($key -in @('silent')) {
                        $argList.Add("-$key") | Out-Null
                    }
                    else {
                        $argList.Add("-$key=enable") | Out-Null
                    }
                }
                # $false means the flag is simply omitted.
            }
            elseif ($val -is [string]) {
                # Single-quote values with a space/comma (double quotes would close the
                # remote pwsh -c wrapper; a bare comma is the array operator).
                if ($val -match '[\s,]') {
                    $escaped = $val -replace "'", "''"
                    $argList.Add("-$key='$escaped'") | Out-Null
                }
                else {
                    $argList.Add("-$key=$val") | Out-Null
                }
            }
        }

        return $argList -join ' '
    }
}
