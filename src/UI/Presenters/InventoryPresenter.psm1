using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\ViewModels\HomeViewModel.psm1"
using module "..\..\Services\InventoryService.psm1"
using module "..\..\Services\DiskUsageService.psm1"

<#
.SYNOPSIS
    Coordinates the Home screen's per-machine detail panel: CIM inventory probe,
    storage scan, and the overview tiles.

.DESCRIPTION
    Extracted from HomePresenter to shed its detail/inventory responsibility (see
    docs/HomePresenter-Split-Plan.md). It owns the detail-panel + overview controls
    and the inventory / disk-scan rendering, while HomePresenter keeps the shared
    AsyncJob pump and forwards the Inventory / DiskScan job kinds here.

.NOTES
    Mirrors the FinderPresenter seam: a duck-typed [object] $Home back-ref reaches
    HomePresenter's machine seams (a typed import would be a using-module cycle).
    Stage 1 of the split (docs/HomePresenter-Split-Plan.md): the class, constructor,
    and seam are in place; the detail state and methods migrate in later stages.
#>
class InventoryPresenter {
    [AppConfig]        $Config
    [LogService]       $Logger
    [HomeViewModel]    $HomeVm
    [InventoryService] $InventoryService
    [DiskUsageService] $DiskUsageService
    [object]           $Store    # RecentConnectionsStore (shared with HomePresenter)
    [object]           $Toasts   # ToastService
    [object]           $Home     # duck-typed back-ref to HomePresenter's machine seams

    InventoryPresenter(
        [AppConfig] $config,
        [LogService] $logger,
        [HomeViewModel] $homeVm,
        [InventoryService] $inventoryService,
        [DiskUsageService] $diskUsageService,
        [object] $store,
        [object] $toasts,
        [object] $homePresenter
    ) {
        $this.Config = $config
        $this.Logger = $logger
        $this.HomeVm = $homeVm
        $this.InventoryService = $inventoryService
        $this.DiskUsageService = $diskUsageService
        $this.Store = $store
        $this.Toasts = $toasts
        $this.Home = $homePresenter
    }

    # Adopts the detail-panel + overview controls from the Home view. Empty until the
    # control fields migrate here in the next stage; the wiring point is fixed now.
    [void] Initialize([System.Windows.FrameworkElement] $view) {
    }
}
