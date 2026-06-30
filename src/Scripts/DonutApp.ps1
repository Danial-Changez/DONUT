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

# Import classes (resolved at parse time)
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

# Initialize Config
try {
    # Initialize ConfigManager and Load Config
    Write-Host "Initializing ConfigManager..."
    # Resolve parent path to maintain 'src' as the root
    $srcRoot = (Resolve-Path "$PSScriptRoot\..").Path
    $configManager = [ConfigManager]::new($srcRoot)
    $global:AppConfig = $configManager.LoadConfig()

    # Ensure appdata folders exist (logs/reports)
    foreach ($folder in @("logs","reports")) {
        $path = Join-Path (Split-Path $configManager.ConfigPath -Parent) $folder
        if (-not (Test-Path $path)) { New-Item -Path $path -ItemType Directory -Force | Out-Null }
    }

    # Central logger (logs directory is guaranteed by ConfigManager). Injected
    # into the collaborators that support it so runtime errors are recorded.
    $logger = [LogService]::new($configManager.LogsPath)
    $logger.LogInfo("DONUT starting up.")
    [RunspaceManager]::SetLogger($logger)

    # Initialize RunspaceManager with ThrottleLimit from config
    $throttleLimit = $global:AppConfig.GetThrottleLimit()
    if ($throttleLimit -lt 1) { $throttleLimit = 5 }
    $logger.LogInfo("Initializing RunspaceManager with ThrottleLimit: $throttleLimit")
    [RunspaceManager]::Initialize(1, $throttleLimit)

    # Initialize Resources
    $logger.LogInfo("Loading resources.")
    $resourceService = [ResourceService]::new($srcRoot, $logger)
    $resourceService.LoadGlobalResources()

    # Check for App Updates
    $logger.LogInfo("Checking for updates.")
    try {
        $selfUpdateService = [SelfUpdateService]::new($logger)
        $updatePresenter = [UpdatePresenter]::new($selfUpdateService, $resourceService)
        $updatePresenter.CheckAndPrompt()
    }
    catch {
        $logger.LogException("Update check failed", $_)
    }

    # Launch Main Window
    $logger.LogInfo("Initializing MainPresenter.")
    $networkProbe = [NetworkProbe]::new($logger)
    $presenter = [MainPresenter]::new($global:AppConfig, $configManager, $networkProbe, $resourceService)
    
    $presenter.Show()
    
}
catch {
    if ($null -ne $logger) { $logger.LogException("Error starting Donut", $_) }
    [System.Windows.Forms.MessageBox]::Show("Error starting Donut: $_", "Error")
}