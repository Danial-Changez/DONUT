using namespace System.Windows
using module "..\..\Models\AppConfig.psm1"
using module "..\..\Models\TourSteps.psm1"
using module "..\..\Core\ConfigManager.psm1"
using module "..\..\Core\LogService.psm1"

<#
.SYNOPSIS
    Drives the first-run guided tour: spotlight + callout, step by step.

.DESCRIPTION
    Walks TourSteps one at a time. For each step it frames the target control with four
    dim panels (leaving a lit "hole"), rings it, and places the callout beside it; a
    welcome step with no target dims the whole window and centers the card. Next/Back
    navigate; Skip/Esc/Done exit and set hasSeenTour so first launch only tours once.

.NOTES
    Targets live in HomeView (a separate namescope), so they're resolved from the
    HomePresenter's control refs, not Window.FindName. Geometry uses TransformToVisual
    into the overlay's space; a missing/zero-size target falls back to a centered card.
    Positioning is deferred to a Loaded-priority dispatch so the overlay is laid out first.
#>
class TourPresenter {
    hidden [object] $Window
    hidden [object] $MainVm
    hidden [object] $Home          # HomePresenter (duck-typed: SearchBar/ModeButton/RunAllButton/MachineList)
    hidden [AppConfig] $Config
    hidden [ConfigManager] $ConfigManager
    hidden [LogService] $Logger

    hidden [object[]] $Steps = @()
    hidden [int] $Index = 0
    hidden [bool] $Wired = $false

    hidden [object] $Overlay
    hidden [object] $DimFull
    hidden [object] $DimTop
    hidden [object] $DimBottom
    hidden [object] $DimLeft
    hidden [object] $DimRight
    hidden [object] $Spotlight
    hidden [object] $Callout
    hidden [object] $StepLabel
    hidden [object] $TitleBlock
    hidden [object] $BodyBlock
    hidden [object] $BtnSkip
    hidden [object] $BtnBack
    hidden [object] $BtnNext

    TourPresenter([object]$window, [object]$mainVm, [object]$homePresenter,
        [AppConfig]$config, [ConfigManager]$configManager, [LogService]$logger) {
        $this.Window = $window
        $this.MainVm = $mainVm
        $this.Home = $homePresenter
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.Logger = $logger
    }

    hidden [bool] EnsureWired() {
        if ($this.Wired) { return $true }
        $this.Overlay = $this.Window.FindName('tourOverlay')
        $this.DimFull = $this.Window.FindName('tourDimFull')
        $this.DimTop = $this.Window.FindName('tourDimTop')
        $this.DimBottom = $this.Window.FindName('tourDimBottom')
        $this.DimLeft = $this.Window.FindName('tourDimLeft')
        $this.DimRight = $this.Window.FindName('tourDimRight')
        $this.Spotlight = $this.Window.FindName('tourSpotlight')
        $this.Callout = $this.Window.FindName('tourCallout')
        $this.StepLabel = $this.Window.FindName('tourStepLabel')
        $this.TitleBlock = $this.Window.FindName('tourTitle')
        $this.BodyBlock = $this.Window.FindName('tourBody')
        $this.BtnSkip = $this.Window.FindName('btnTourSkip')
        $this.BtnBack = $this.Window.FindName('btnTourBack')
        $this.BtnNext = $this.Window.FindName('btnTourNext')
        if (-not ($this.Overlay -and $this.Callout -and $this.BtnNext)) {
            $this.Logger.LogWarning('Guided tour controls not found; skipping tour.')
            return $false
        }
        $self = $this
        $this.BtnSkip.Add_Click({ param($s, $e) $self.Finish() }.GetNewClosure())
        $this.BtnBack.Add_Click({ param($s, $e) $self.Back() }.GetNewClosure())
        $this.BtnNext.Add_Click({ param($s, $e) $self.Next() }.GetNewClosure())
        $this.Wired = $true
        return $true
    }

    # Starts (or replays) the tour from step one.
    [void] Start() {
        if (-not $this.EnsureWired()) { return }
        $this.Steps = [TourSteps]::Build()
        $this.Index = 0
        $this.MainVm.Set('IsTourOpen', $true)
        # Defer so the just-shown overlay has laid out (ActualWidth/Height, target bounds).
        $self = $this
        $this.Window.Dispatcher.BeginInvoke(
            [action] { $self.ShowStep($self.GetIndex()) },
            [System.Windows.Threading.DispatcherPriority]::Loaded) | Out-Null
    }

    # Auto-run once on first launch (the ? button calls Start directly to replay).
    [void] MaybeStartFirstRun() {
        if ($this.Config.GetHasSeenTour()) { return }
        if ($this.MainVm -and $this.MainVm.IsTourOpen) { return }
        $this.Start()
    }

    hidden [int] GetIndex() { return $this.Index }

    [void] Next() {
        if ($this.Index -ge ($this.Steps.Count - 1)) { $this.Finish(); return }
        $this.Index++
        $this.ShowStep($this.Index)
    }

    [void] Back() {
        if ($this.Index -le 0) { return }
        $this.Index--
        $this.ShowStep($this.Index)
    }

    # Ends the tour and remembers it (so first launch only tours once).
    [void] Finish() {
        $this.MarkSeen()
        if ($this.MainVm) { $this.MainVm.Set('IsTourOpen', $false) }
    }

    hidden [void] MarkSeen() {
        if ($this.Config.GetHasSeenTour()) { return }
        try {
            $this.Config.SetSetting('hasSeenTour', $true)
            $this.ConfigManager.SaveConfig($this.Config)
        }
        catch { $this.Logger.LogException('Could not persist hasSeenTour', $_) }
    }

    hidden [void] ShowStep([int]$index) {
        if ($index -lt 0 -or $index -ge $this.Steps.Count) { return }
        $step = $this.Steps[$index]
        $last = ($index -eq ($this.Steps.Count - 1))

        $this.StepLabel.Text = "Step $($index + 1) of $($this.Steps.Count)"
        $this.TitleBlock.Text = $step.Title
        $this.BodyBlock.Text = $step.Body
        $this.BtnNext.Content = if ($last) { 'Done' } else { 'Next' }
        $this.BtnBack.Visibility = if ($index -eq 0) { 'Collapsed' } else { 'Visible' }

        $target = if ([string]::IsNullOrWhiteSpace($step.TargetKey)) { $null } else { $this.ResolveTarget($step.TargetKey) }
        if ($null -eq $target -or $target.ActualWidth -le 0 -or $target.ActualHeight -le 0) {
            $this.ShowCentered()
            return
        }
        $this.ShowSpotlight($target, $step.Placement)
    }

    # Welcome / fallback: dim the whole window and centre the card.
    hidden [void] ShowCentered() {
        $this.DimFull.Visibility = 'Visible'
        foreach ($d in @($this.DimTop, $this.DimBottom, $this.DimLeft, $this.DimRight)) { $d.Visibility = 'Collapsed' }
        $this.Spotlight.Visibility = 'Collapsed'
        $this.Callout.HorizontalAlignment = 'Center'
        $this.Callout.VerticalAlignment = 'Center'
        $this.Callout.Margin = [Thickness]::new(0)
    }

    hidden [void] ShowSpotlight([object]$target, [string]$placement) {
        $this.DimFull.Visibility = 'Collapsed'
        foreach ($d in @($this.DimTop, $this.DimBottom, $this.DimLeft, $this.DimRight)) { $d.Visibility = 'Visible' }

        $tl = $target.TransformToVisual($this.Overlay).Transform([Point]::new(0, 0))
        $pad = 6.0
        $ow = $this.Overlay.ActualWidth
        $oh = $this.Overlay.ActualHeight
        $x = [Math]::Max(0, $tl.X - $pad)
        $y = [Math]::Max(0, $tl.Y - $pad)
        $rw = [Math]::Min($ow - $x, $target.ActualWidth + 2 * $pad)
        $rh = [Math]::Min($oh - $y, $target.ActualHeight + 2 * $pad)

        # Four panels frame the lit hole.
        $this.DimTop.Height = $y
        $this.DimBottom.Height = [Math]::Max(0, $oh - ($y + $rh))
        $this.DimLeft.Margin = [Thickness]::new(0, $y, 0, 0)
        $this.DimLeft.Height = $rh
        $this.DimLeft.Width = $x
        $this.DimRight.Margin = [Thickness]::new(0, $y, 0, 0)
        $this.DimRight.Height = $rh
        $this.DimRight.Width = [Math]::Max(0, $ow - ($x + $rw))

        # Spotlight ring over the target.
        $this.Spotlight.Margin = [Thickness]::new($x, $y, 0, 0)
        $this.Spotlight.Width = $rw
        $this.Spotlight.Height = $rh
        $this.Spotlight.Visibility = 'Visible'

        $this.PlaceCallout($x, $y, $rw, $rh, $placement, $ow, $oh)
    }

    hidden [void] PlaceCallout([double]$x, [double]$y, [double]$rw, [double]$rh, [string]$placement, [double]$ow, [double]$oh) {
        $cw = 340.0
        $this.Callout.UpdateLayout()
        $ch = if ($this.Callout.ActualHeight -gt 0) { $this.Callout.ActualHeight } else { 170.0 }
        $gap = 14.0

        $cx = $x
        $cy = $y + $rh + $gap   # default: below
        switch ($placement) {
            'above' { $cx = $x; $cy = $y - $ch - $gap }
            'right' { $cx = $x + $rw + $gap; $cy = $y }
            'left' { $cx = $x - $cw - $gap; $cy = $y }
        }
        # Keep it fully on-screen.
        $cx = [Math]::Max(8, [Math]::Min($cx, $ow - $cw - 8))
        $cy = [Math]::Max(8, [Math]::Min($cy, $oh - $ch - 8))

        $this.Callout.HorizontalAlignment = 'Left'
        $this.Callout.VerticalAlignment = 'Top'
        $this.Callout.Margin = [Thickness]::new($cx, $cy, 0, 0)
    }

    hidden [object] ResolveTarget([string]$key) {
        if ($null -eq $this.Home) { return $null }
        switch ($key) {
            'search' { return $this.Home.SearchBar }
            'mode' { return $this.Home.ModeButton }
            'runAll' { return $this.Home.RunAllButton }
            'list' { return $this.Home.MachineList }
            'settings' { return $this.Window.FindName('btnSettings') }
            'help' { return $this.Window.FindName('btnHelp') }
            default { return $null }
        }
        return $null
    }
}
