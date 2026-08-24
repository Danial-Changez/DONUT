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

        # TagText and OvModelSub are decorated, so copying them pastes junk.
        It "copies the raw value, never the decorated label" -Skip:(-not $script:isStaMode) {
            $decorated = 'TagText', 'OvModelSub'
            $views = 'UI\Views\Home\DetailPane.xaml', 'UI\Views\Home\LensPane.xaml',
            'UI\Views\Home\StatCards.xaml', 'UI\Views\MainWindow.xaml'
            foreach ($view in $views) {
                $raw = Get-Content (Join-Path $script:srcRoot $view) -Raw
                foreach ($bad in $decorated) {
                    # Tag carries the clipboard payload; CommandParameter does on the one glyph.
                    $raw | Should -Not -Match "Tag=`"\{Binding [^}]*$bad\}" `
                        -Because "$view must copy the underlying value, not $bad"
                    $raw | Should -Not -Match "CommandParameter=`"\{Binding [^}]*$bad\}" `
                        -Because "$view must copy the underlying value, not $bad"
                }
            }
        }

        # Every copyable value needs a payload, or the click silently copies nothing.
        It "gives every copyable value a Tag to copy" -Skip:(-not $script:isStaMode) {
            $views = 'UI\Views\Home\DetailPane.xaml', 'UI\Views\Home\LensPane.xaml',
            'UI\Views\Home\StatCards.xaml', 'UI\Views\MainWindow.xaml'
            $total = 0
            foreach ($view in $views) {
                $raw = Get-Content (Join-Path $script:srcRoot $view) -Raw
                $uses = [regex]::Matches($raw, 'CopyableValue')
                $total += $uses.Count
                foreach ($m in [regex]::Matches($raw, '(?s)<TextBox[^>]*?CopyableValue.*?/>')) {
                    $m.Value | Should -Match 'Tag="\{Binding ' -Because "a CopyableValue in $view needs a Tag"
                }
            }
            $total | Should -Be 8 -Because 'eight values are their own copy target'
        }

        # The presenter wires RequestNavigate by name, so a rename breaks the link silently.
        It "keeps the update prompt's release link findable" -Skip:(-not $script:isStaMode) {
            $dlg = [ViewLoader]::Load($script:srcRoot, 'UI\Views\DialogWindow.xaml')
            $dlg.FindName('linkRelease') | Should -Not -BeNullOrEmpty
        }

        # The headline values were TextBlocks, so only the grey sub-lines could be copied.
        It "keeps every stat card value selectable" -Skip:(-not $script:isStaMode) {
            $cards = [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\StatCards.xaml')
            $boxes = @()
            $walk = {
                param($node)
                $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
                for ($i = 0; $i -lt $n; $i++) {
                    $c = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
                    if ($c -is [System.Windows.Controls.TextBox]) { $script:found += $c }
                    & $walk $c
                }
            }
            $cards.Measure([System.Windows.Size]::new(1200, 400))
            $cards.Arrange([System.Windows.Rect]::new(0, 0, 1200, 400))
            $script:found = @()
            & $walk $cards
            $boxes = @($script:found | Where-Object {
                    $b = [System.Windows.Data.BindingOperations]::GetBinding(
                        $_, [System.Windows.Controls.TextBox]::TextProperty)
                    $b -and $b.Path.Path -in @('SelectedMachine.OvModel', 'SelectedMachine.OvBattery',
                        'SelectedMachine.OvDisk', 'SelectedMachine.OvBios')
                })
            $boxes.Count | Should -Be 4 -Because 'model, battery, disk and BIOS must all be copyable'
        }

        It "hosts the Lens slot inside the detail region, not the shell" -Skip:(-not $script:isStaMode) {
            $shell = [ViewLoader]::Load($script:srcRoot, 'UI\Views\HomeView.xaml')
            $detail = [ViewLoader]::Load($script:srcRoot, 'UI\Views\Home\DetailPane.xaml')
            $shell.FindName('slotLens') | Should -BeNullOrEmpty
            $detail.FindName('slotLens') | Should -Not -BeNullOrEmpty
        }
    }
}
