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
using module "..\Core\AsyncJob.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\RunspaceManager.psm1"
using module "..\Core\LogService.psm1"
using module "..\Services\DriverMatchingService.psm1"
using module "..\Services\ActiveDirectoryService.psm1"
using module "..\Services\RemoteServices.psm1"
using module "..\Services\SelfUpdateService.psm1"
using module "..\UI\Presenters\DialogPresenter.psm1"
using module "..\UI\Presenters\ConfigPresenter.psm1"
using module "..\UI\Presenters\LogsPresenter.psm1"
using module "..\UI\Presenters\HomePresenter.psm1"
using module "..\UI\Presenters\MainPresenter.psm1"
using module "..\UI\Presenters\LoginPresenter.psm1"
using module "..\UI\Presenters\UpdatePresenter.psm1"
using module "..\Services\ResourceService.psm1"

try {
    Write-Host "Initializing ConfigManager..."
    # Resolve the parent of Scripts\ so 'src' stays the root.
    $srcRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $configManager = [ConfigManager]::new($srcRoot)
    $global:AppConfig = $configManager.LoadConfig()

    foreach ($folder in @("logs","reports")) {
        $path = Join-Path (Split-Path $configManager.ConfigPath -Parent) $folder
        if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
    }

    # Central logger (logs directory is guaranteed by ConfigManager). Injected
    # into the collaborators that support it so runtime errors are recorded.
    $logger = [LogService]::new($configManager.LogsPath)
    $logger.LogInfo("DONUT starting up.")
    [RunspaceManager]::SetLogger($logger)

    $throttleLimit = $global:AppConfig.GetThrottleLimit()
    if ($throttleLimit -lt 1) { $throttleLimit = 5 }
    $logger.LogInfo("Initializing RunspaceManager with ThrottleLimit: $throttleLimit")
    [RunspaceManager]::Initialize(1, $throttleLimit)

    $logger.LogInfo("Loading resources.")
    $resourceService = [ResourceService]::new($srcRoot, $logger)
    $resourceService.LoadGlobalResources()

    $logger.LogInfo("Preparing self-update + main window.")
    $networkProbe = [NetworkProbe]::new($logger)
    $selfUpdateService = [SelfUpdateService]::new($logger)
    $updatePresenter = [UpdatePresenter]::new($selfUpdateService, $resourceService)

    # Build the main window (and warm the runspace pool) BEFORE showing login. No window is
    # on screen yet, so the pool warm's brief synchronous block is just a normal launch
    # delay - not a frozen login window (which is what happened when the build ran during
    # the login modal). Login + any update prompt then run, and the already-built,
    # already-warmed window is shown the instant they finish.
    $mainPresenter = $null
    try {
        $mainPresenter = [MainPresenter]::new($global:AppConfig, $configManager, $networkProbe, $resourceService)
        $logger.LogInfo("Main window preloaded (runspace pool warmed).")
    }
    catch {
        $logger.LogException("Main window preload failed", $_)
    }

    try {
        # Sign-in (if needed) + update check / prompt, before the main window shows.
        $updatePresenter.CheckAndPrompt()
    }
    catch {
        $logger.LogException("Update check failed", $_)
    }

    if ($null -ne $mainPresenter) {
        $mainPresenter.Show()
    }
    else {
        $logger.LogError("Main window could not be built.")
    }
    
}
catch {
    if ($null -ne $logger) { $logger.LogException("Error starting Donut", $_) }
    [System.Windows.Forms.MessageBox]::Show("Error starting Donut: $_", "Error")
}