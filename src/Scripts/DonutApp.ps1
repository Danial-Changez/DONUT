<#
.SYNOPSIS
    Builds the DONUT application graph and shows the main window.

.DESCRIPTION
    Dot-sourced by Start-Donut.ps1. Imports every class module at parse time
    (using module, in dependency order: Models -> Core -> Services ->
    Presenters), loads or creates the AppConfig via ConfigManager, ensures the
    data root's logs/reports folders exist, wires the central LogService
    and the runspace pool (throttle from config), constructs MainPresenter and
    runs the WPF message loop.

.NOTES
    Classes are resolved at parse time, so the using-module graph below must stay
    in dependency order.

    Elevation is decided here, not by the manifest: app.manifest is asInvoker so DONUT
    can also run de-elevated, and runAsAdmin is what actually relaunches it. A tray
    start is the exception and never elevates - the prompt would land on the sign-in
    screen, and from a standard console account it asks for credentials, not consent.
    That instance reports its limited capability once the window is surfaced instead.
    A failed or declined attempt never writes runAsAdmin: one cancelled prompt must not
    demote DONUT permanently.
#>

using module "..\Models\AppConfig.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Models\AdSearchResult.psm1"
using module "..\Models\TempPassword.psm1"
using module "..\Core\AsyncJob.psm1"
using module "..\Core\WorkerProcess.psm1"
using module "..\Core\BuildProvenance.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\ElevationContext.psm1"
using module "..\Core\ElevationRelaunch.psm1"
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

# $global:Splash is injected by Donut.Launcher, absent on the dev pwsh path, so these
# no-op there.
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

    # Roll an oversized log first: it grows unbounded across runs otherwise.
    [LogService]::Rotate($configManager.LogsPath, 10MB)
    $logger = [LogService]::new($configManager.LogsPath)
    # The debug gate is the persisted setting or the -DebugLog session override.
    $logger.DebugEnabled = $global:AppConfig.GetDebugLogging() -or [bool]$global:DebugLogStart
    $logger.LogInfo("DONUT starting up.")
    if ($logger.DebugEnabled) {
        $src = if ($global:DebugLogStart) { '-DebugLog session override' } else { 'debugLogging setting' }
        $logger.LogInfo("Debug logging enabled ($src).")
    }
    # Provenance first: every field log must name the exact code that produced it.
    $logger.LogInfo([BuildProvenance]::Stamp($srcRoot))
    [RunspaceManager]::SetLogger($logger)

    # The launcher sets $global:StartHidden, and the dev path sets $global:TrayStart.
    $hidden = [bool]$global:StartHidden -or [bool]$global:TrayStart

    # Honoured here because the manifest is asInvoker, and as early as possible. See .NOTES.
    $limitedCapability = $false
    if ($global:AppConfig.GetRunAsAdmin() -and -not [ElevationContext]::IsElevated()) {
        if ($hidden) {
            # A logon start must never throw a credential prompt at the sign-in screen.
            $limitedCapability = $true
            $logger.LogInfo('Autostarted de-elevated: elevating at logon would prompt for credentials.')
        }
        else {
            $spawn = [ElevationRelaunch]::Spawn([ElevationRelaunch]::BuildSpec($srcRoot))
            if ($spawn.Ok) {
                $logger.LogInfo('Relaunching elevated; this instance is exiting before it builds anything.')
                Close-Splash
                return
            }
            # runAsAdmin stays unwritten: one declined prompt must not demote DONUT.
            $limitedCapability = $true
            if ($spawn.Declined) { $logger.LogInfo('Elevation declined at startup; continuing de-elevated.') }
            else { $logger.LogError("Could not elevate at startup: $($spawn.Reason)") }
        }
    }

    $throttleLimit = $global:AppConfig.GetThrottleLimit()
    if ($throttleLimit -lt 1) { $throttleLimit = 5 }
    # Initialize raises the ThreadPool floor first, guarding against dispatch starvation.
    $logger.LogInfo("Initializing RunspaceManager with ThrottleLimit: $throttleLimit")
    # min = max pins every runspace, or warmed ones die and later jobs cold-load.
    [RunspaceManager]::Initialize($throttleLimit, $throttleLimit)
    Update-Splash 44 'Warming runspace pool'

    $logger.LogInfo("Loading resources.")
    $resourceService = [ResourceService]::new($srcRoot, $logger)
    $resourceService.LoadGlobalResources()
    Update-Splash 66 'Loading resources'

    $logger.LogInfo("Preparing self-update + main window.")
    $networkProbe = [NetworkProbe]::new($logger)

    # The repo ships nothing org-specific, so a first run discovers these and persists them.
    $discovered = $false
    if (-not $global:AppConfig.GetDomains()) {
        $domains = @($networkProbe.DiscoverSearchDomains())
        if ($domains) {
            $global:AppConfig.SetSetting('domains', $domains)
            $logger.LogInfo("Discovered search domains: $($domains -join ', ')")
            $discovered = $true
        }
        else {
            $logger.LogWarning('No search domains discovered (off-domain?); the finder searches nothing until config names them.')
        }
    }
    if (-not $global:AppConfig.GetAdminServiceHost()) {
        $site = $networkProbe.DiscoverSiteServer()
        if ($site) {
            $global:AppConfig.SetSetting('adminServiceHost', $site)
            $logger.LogInfo("Discovered SCCM management point: $site")
            $discovered = $true
        }
    }
    if ($discovered) { $configManager.SaveConfig($global:AppConfig) }
    $selfUpdateService = [SelfUpdateService]::new($logger)
    $updatePresenter = [UpdatePresenter]::new($selfUpdateService, $resourceService)

    # With no window on screen the synchronous warm is launch delay, not a frozen modal.
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

    # Everything past this point is interactive, not unattended loading.
    Close-Splash

    if ($null -ne $mainPresenter) {
        # A toast fired into a hidden tray start is never seen, so it waits for the window.
        $mainPresenter.PendingLimitedNotice = $limitedCapability

        # Deferred past the startup crunch: as a boot-time job it raced the warm shells.
        $startupTaskTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $startupTaskTimer.Interval = [TimeSpan]::FromSeconds(120)
        $startupTaskTimer.Add_Tick({
                $startupTaskTimer.Stop()
                # A heal must never prompt, and de-elevated this only toasts a failure.
                if ([ElevationContext]::IsElevated()) { $mainPresenter.ApplyStartupTask() }
            }.GetNewClosure())
        $startupTaskTimer.Start()

        # Waits for the window so the resume can log and toast into it. Short, not a heal.
        $resumeTimer = [System.Windows.Threading.DispatcherTimer]::new()
        $resumeTimer.Interval = [TimeSpan]::FromSeconds(3)
        $resumeTimer.Add_Tick({
                $resumeTimer.Stop()
                $mainPresenter.ResumePendingIntent()
            }.GetNewClosure())
        $resumeTimer.Start()

        if ($hidden) {
            $logger.LogInfo("Starting hidden in the system tray.")
            # Defer sign-in/update to the first time the user surfaces the window.
            $mainPresenter.PendingUpdateCheck = $updatePresenter
            $mainPresenter.ShowHidden()
        }
        else {
            try {
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
    [System.Windows.Forms.MessageBox]::Show("DONUT could not start. $_", "Startup Error")
}
