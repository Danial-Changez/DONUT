<#
.SYNOPSIS
    Builds the DONUT application graph and shows the main window.

.DESCRIPTION
    Dot-sourced by Start-Donut.ps1. Imports every class module at parse time
    (using module, in dependency order: Models -> Core -> Services ->
    Presenters), loads or creates the AppConfig via ConfigManager, ensures the
    %LOCALAPPDATA%\DONUT logs/reports folders exist, wires the central LogService
    and the runspace pool (throttle from config), constructs MainPresenter and
    runs the WPF message loop.

.NOTES
    Classes are resolved at parse time, so the using-module graph below must stay
    in dependency order.
#>

using module "..\Models\AppConfig.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AdSearchResult.psm1"
using module "..\Models\TempPassword.psm1"
using module "..\Core\AsyncJob.psm1"
using module "..\Core\WorkerProcess.psm1"
using module "..\Core\BuildProvenance.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\RunspaceManager.psm1"
using module "..\Core\LogService.psm1"
using module "..\Services\DriverMatchingService.psm1"
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Services\RemoteServices.psm1"
using module "..\Services\SelfUpdateService.psm1"
using module "..\UI\Presenters\DialogPresenter.psm1"
using module "..\UI\Presenters\SettingsPresenter.psm1"
using module "..\UI\Presenters\HomePresenter.psm1"
using module "..\UI\Presenters\MainPresenter.psm1"
using module "..\UI\Presenters\LoginPresenter.psm1"
using module "..\UI\Presenters\UpdatePresenter.psm1"
using module "..\Services\ResourceService.psm1"

# Splash progress helpers. $global:Splash is injected by Donut.Launcher (absent on the dev
# pwsh path, so these no-op there).
function Update-Splash([int]$Percent, [string]$Status) {
    if ($global:Splash) { try { $global:Splash.Report($Percent, $Status) } catch { } }
}
function Close-Splash {
    if ($global:Splash) { try { $global:Splash.Complete() } catch { } }
}

try {
    Write-Host "Initializing ConfigManager..."
    # Resolve the parent of Scripts\ so 'src' stays the root.
    $srcRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $configManager = [ConfigManager]::new($srcRoot)
    $global:AppConfig = $configManager.LoadConfig()
    Update-Splash 18 'Loading configuration'

    foreach ($folder in @("logs", "reports")) {
        $path = Join-Path (Split-Path $configManager.ConfigPath -Parent) $folder
        if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
    }

    # Central logger (logs directory is guaranteed by ConfigManager). Injected
    # into the collaborators that support it so runtime errors are recorded.
    $logger = [LogService]::new($configManager.LogsPath)
    # DEBUG gate: the persisted setting, or the -DebugLog session override.
    $logger.DebugEnabled = $global:AppConfig.GetDebugLogging() -or [bool]$global:DebugLogStart
    $logger.LogInfo("DONUT starting up.")
    if ($logger.DebugEnabled) {
        $src = if ($global:DebugLogStart) { '-DebugLog session override' } else { 'debugLogging setting' }
        $logger.LogInfo("Debug logging enabled ($src).")
    }
    # Provenance first: every field log must name the exact code that produced it.
    $logger.LogInfo([BuildProvenance]::Stamp($srcRoot))
    [RunspaceManager]::SetLogger($logger)

    $throttleLimit = $global:AppConfig.GetThrottleLimit()
    if ($throttleLimit -lt 1) { $throttleLimit = 5 }
    # RunspaceManager.Initialize raises the ThreadPool floor before it opens the pool
    # (dispatch starvation guard - architecture/runspaces-and-workers: ThreadPool floor).
    $logger.LogInfo("Initializing RunspaceManager with ThrottleLimit: $throttleLimit")
    # min = max pins every runspace: idle cleanup only disposes above the minimum, so
    # min=1 let warmed runspaces die and later jobs cold-load under the loader lock.
    [RunspaceManager]::Initialize($throttleLimit, $throttleLimit)
    Update-Splash 44 'Warming runspace pool'

    $logger.LogInfo("Loading resources.")
    $resourceService = [ResourceService]::new($srcRoot, $logger)
    $resourceService.LoadGlobalResources()
    Update-Splash 66 'Loading resources'

    $logger.LogInfo("Preparing self-update + main window.")
    $networkProbe = [NetworkProbe]::new($logger)
    $selfUpdateService = [SelfUpdateService]::new($logger)
    $updatePresenter = [UpdatePresenter]::new($selfUpdateService, $resourceService)

    # Build the main window (and warm the pool) before showing login: with no window
    # on screen the synchronous warm is just launch delay, not a frozen login modal.
    $mainPresenter = $null
    try {
        $mainPresenter = [MainPresenter]::new(
            $global:AppConfig, $configManager, $networkProbe, $resourceService)
        $logger.LogInfo("Main window preloaded (runspace pool warmed).")
        Update-Splash 90 'Preparing sign-in'
    }
    catch {
        $logger.LogException("Main window preload failed", $_)
    }

    # Close the splash before sign-in/update: everything past this point is interactive
    # (a login or update prompt may appear), not unattended loading.
    Close-Splash

    # Hidden (tray) start: launcher sets $global:StartHidden; the dev path sets
    # $global:TrayStart from Start-Donut.ps1's -Tray switch.
    $hidden = [bool]$global:StartHidden -or [bool]$global:TrayStart

    if ($null -ne $mainPresenter) {
        # Heal the startup task DEFERRED past the startup crunch - as a boot-time
        # pool job it raced the warm shells (architecture/runspaces-and-workers: startup staging).
        $startupTaskTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $startupTaskTimer.Interval = [TimeSpan]::FromSeconds(120)
        $startupTaskTimer.Add_Tick({
                $startupTaskTimer.Stop()
                $mainPresenter.ApplyStartupTask()
            }.GetNewClosure())
        $startupTaskTimer.Start()

        if ($hidden) {
            $logger.LogInfo("Starting hidden in the system tray.")
            # Defer sign-in/update to the first time the user surfaces the window.
            $mainPresenter.PendingUpdateCheck = $updatePresenter
            $mainPresenter.ShowHidden()
        }
        else {
            try {
                # Sign-in (if needed) + update check / prompt, before the window shows.
                $updatePresenter.CheckAndPrompt()
            }
            catch {
                $logger.LogException("Update check failed", $_)
            }
            $mainPresenter.Show()
        }
    }
    else {
        $logger.LogError("Main window could not be built.")
    }

}
catch {
    Close-Splash
    if ($null -ne $logger) { $logger.LogException("Error starting Donut", $_) }
    [System.Windows.Forms.MessageBox]::Show("Error starting Donut: $_", "Error")
}
