# Integration tests for view composition, which need WPF in STA mode.
using module "..\..\src\Core\ViewLoader.psm1"

BeforeDiscovery {
    # Check STA mode at discovery time so -Skip works correctly
    $script:isStaMode = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq
    [System.Threading.ApartmentState]::STA
    # Discovery runs before BeforeAll, so the -ForEach list resolves the views path itself.
    $script:discoveredViews = @(
        Get-ChildItem -Path (Join-Path (Resolve-Path (Join-Path $PSScriptRoot "..\..\src")).Path "UI\Views") `
                      -Filter '*.xaml' `
                      -Recurse |
            ForEach-Object { $_.FullName.Substring($_.FullName.IndexOf('UI')) }
    )
}

Describe "View composition" -Tag "Integration", "WPF" {

    BeforeAll {
        $script:srcRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\src")).Path
        $script:viewsPath = Join-Path $script:srcRoot "UI\Views"
    }

    Context "Every view file loads standalone" {
        It "loads <_> via ViewLoader" -Skip:(-not $script:isStaMode) -ForEach $script:discoveredViews {
            # A missed per-file StaticResource (e.g. BoolToVis) throws right here.
            $root = [ViewLoader]::Load($script:srcRoot, $_)
            $root | Should -Not -BeNullOrEmpty
        }

        It "throws a loud, path-naming error for a missing region" -Skip:(-not $script:isStaMode) {
            { [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\Nope.xaml') } |
                Should -Throw '*Nope.xaml*'
        }
    }

    Context "Home shell contract" {
        It "exposes the four region slots" -Skip:(-not $script:isStaMode) {
            $shell = [ViewLoader]::Load($script:srcRoot, 'UI\Views\HomeView.xaml')
            foreach ($slot in 'slotActionBar', 'slotStatCards', 'slotMachinePane', 'slotDetailArea') {
                $shell.FindName($slot) | Should -Not -BeNullOrEmpty -Because "the shell must host $slot"
            }
        }

        It "keeps slots out of the tab order" -Skip:(-not $script:isStaMode) {
            $shell = [ViewLoader]::Load($script:srcRoot, 'UI\Views\HomeView.xaml')
            foreach ($slot in 'slotActionBar', 'slotStatCards', 'slotMachinePane', 'slotDetailArea') {
                $c = $shell.FindName($slot)
                $c.Focusable | Should -BeFalse
                $c.IsTabStop | Should -BeFalse
            }
        }

        It "resolves the tour targets across region namescopes" -Skip:(-not $script:isStaMode) {
            # Mirrors HomePresenter.FindHomeElement: root Name first, then FindName.
            $roots = @(
                [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\ActionBar.xaml')
                [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\MachinePane.xaml')
                [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\DetailPane.xaml')
            )
            foreach ($name in 'SearchBox', 'btnMode', 'MachinePanel', 'DetailPane') {
                $hit = $null
                foreach ($root in $roots) {
                    if ($root.Name -eq $name) { $hit = $root; break }
                    $hit = $root.FindName($name)
                    if ($hit) { break }
                }
                $hit | Should -Not -BeNullOrEmpty -Because "the tour spotlights $name"
            }
        }

        It "hosts the Lens slot inside the detail region, not the shell" -Skip:(-not $script:isStaMode) {
            $shell = [ViewLoader]::Load($script:srcRoot, 'UI\Views\HomeView.xaml')
            $detail = [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\DetailPane.xaml')
            $shell.FindName('slotLens') | Should -BeNullOrEmpty
            $detail.FindName('slotLens') | Should -Not -BeNullOrEmpty
        }
    }
}
