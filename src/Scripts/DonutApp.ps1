# Import Classes (Read at ParseTime)
using module "..\Models\AppConfig.psm1"
using module "..\Models\DeviceContext.psm1"
using module "..\Core\AsyncJob.psm1"
using module "..\Core\ConfigManager.psm1"
using module "..\Core\NetworkProbe.psm1"
using module "..\Core\RunspaceManager.psm1"
using module "..\Services\LogService.psm1"
using module "..\Services\DriverMatchingService.psm1"
using module "..\Services\RemoteServices.psm1"
using module "..\Services\SelfUpdateService.psm1"
using module "..\UI\Presenters\DialogPresenter.psm1"
using module "..\UI\Presenters\ConfigPresenter.psm1"
using module "..\UI\Presenters\LogsPresenter.psm1"
using module "..\UI\Presenters\HomePresenter.psm1"
using module "..\UI\Presenters\BatteryPresenter.psm1"
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
    
    # Initialize RunspaceManager with ThrottleLimit from config
    $throttleLimit = $global:AppConfig.GetThrottleLimit()
    if ($throttleLimit -lt 1) { $throttleLimit = 5 }
    Write-Host "Initializing RunspaceManager with ThrottleLimit: $throttleLimit"
    [RunspaceManager]::Initialize(1, $throttleLimit)
    
    # Initialize Resources
    Write-Host "Loading Resources..."
    $resourceService = [ResourceService]::new($srcRoot)
    $resourceService.LoadGlobalResources()

    # Check for App Updates
    Write-Host "Checking for updates..."
    try {
        $updatePresenter = [UpdatePresenter]::new($resourceService)
        $updatePresenter.CheckAndPrompt()
    }
    catch {
        Write-Warning "Update check failed: $_"
    }

    # Launch Main Window
    Write-Host "Initializing MainPresenter..."
    $networkProbe = [NetworkProbe]::new()
    $presenter = [MainPresenter]::new($global:AppConfig, $configManager, $networkProbe, $resourceService)
    
    $presenter.Show()
    
}
catch {
    Write-Error "Error starting Donut: $_"
    [System.Windows.Forms.MessageBox]::Show("Error starting Donut: $_", "Error")
}