using namespace System.Windows.Controls
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Core\LogService.psm1"
using module "..\ViewModels\HomeViewModel.psm1"
using module "..\..\Services\InventoryService.psm1"
using module "..\..\Services\DiskUsageService.psm1"
using module "..\..\Models\MachineInventory.psm1"
using module "..\..\Models\RecentConnection.psm1"

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

    # Detail-header controls (binding-driven, so no method reads them yet). The detail
    # log, progress bar, and probe buttons stay with HomePresenter until stage 3.
    [System.Windows.UIElement] $DetailEmptyHint
    [System.Windows.UIElement] $DetailContent
    [TextBlock] $DetailHostText
    [TextBlock] $DetailProbed

    # Overview tile controls (mirror the selected remote machine)
    [TextBlock] $OvModel
    [TextBlock] $OvModelSub
    [TextBlock] $OvBattery
    [TextBlock] $OvBatterySub
    [TextBlock] $OvDisk
    [TextBlock] $OvDiskSub
    [TextBlock] $OvUpdates
    [TextBlock] $OvUpdatesSub

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

    # Adopts the detail-header + overview tile controls from the Home view. The detail
    # log, progress bar, and probe buttons migrate with the probe lifecycle (stage 3).
    [void] Initialize([System.Windows.FrameworkElement] $view) {
        $this.DetailEmptyHint = $view.FindName('DetailEmptyHint')
        $this.DetailContent = $view.FindName('DetailContent')
        $this.DetailHostText = $view.FindName('txtDetailHost')
        $this.DetailProbed = $view.FindName('txtDetailProbed')

        $this.OvModel = $view.FindName('txtOvModel')
        $this.OvModelSub = $view.FindName('txtOvModelSub')
        $this.OvBattery = $view.FindName('txtOvBattery')
        $this.OvBatterySub = $view.FindName('txtOvBatterySub')
        $this.OvDisk = $view.FindName('txtOvDisk')
        $this.OvDiskSub = $view.FindName('txtOvDiskSub')
        $this.OvUpdates = $view.FindName('txtOvUpdates')
        $this.OvUpdatesSub = $view.FindName('txtOvUpdatesSub')
    }

    # Sets the detail-header subtitle (IP + probe freshness) on the host's view-model.
    hidden [void] RenderDetailSubtitle([string]$hostName, [string]$probedIso) {
        $vm = $this.Home.GetRow($hostName)
        if ($vm) { $vm.SetProbed($this.Home.Resolver.GetCachedIp($hostName), $probedIso) }
    }

    # Syncs the host view-model's detail/overview bindables from its inventory.
    [void] PopulateDetailCards([string]$hostName, [MachineInventory]$inv, [RecentConnection]$rc) {
        $vm = $this.Home.GetRow($hostName)
        if ($null -eq $vm) { return }
        $useInv = if ($null -ne $inv) { $inv }
        elseif ($null -ne $rc) { $rc.Inventory }
        else { $null }
        if ($null -ne $useInv) { $vm.ApplyInventory($useInv) }
        $probedIso = if ($null -ne $useInv -and $useInv.ProbedAt) { $useInv.ProbedAt } else { '' }
        $vm.SetProbed($this.Home.Resolver.GetCachedIp($hostName), $probedIso)
        $vm.SetPendingUpdates($(if ($null -ne $rc) { $rc.UpdateCount } else { 0 }))
    }

    # Re-renders the overview strip (e.g. after a job changes pending-update counts).
    [void] RefreshOverview() {
        $this.UpdateOverviewTiles()
    }

    # No-op: the overview strip is fully binding-driven; kept for existing callers.
    [void] UpdateOverviewTiles() { }
}
