<#
    Static guards for the single-source row palette: UIColors.xaml owns the accent
    hexes; HostViewModel only holds brushes the presenter resolved (SeedRowPalette).
    Text-based so it runs on Linux where the WPF modules cannot load.
#>

Describe "Row palette single-source" {

    BeforeAll {
        $script:VmPath = Join-Path $PSScriptRoot '../../src/UI/ViewModels/HostViewModel.psm1'
        $script:PresenterPath = Join-Path $PSScriptRoot '../../src/UI/Presenters/HomePresenter.psm1'
        $script:ColorsPath = Join-Path $PSScriptRoot '../../src/UI/Styles/UIColors.xaml'
        $script:VmText = Get-Content -LiteralPath $script:VmPath -Raw
        $script:PresenterText = Get-Content -LiteralPath $script:PresenterPath -Raw
        # The status accents rows key into the palette with (see HostViewModel.IdleColorKey
        # and FleetCardStatus color keys).
        $script:PaletteKeys = @('AccentGreen', 'AccentRed', 'AccentYellow', 'AccentOrange',
            'AccentCyan', 'AccentPurple', 'BodyTextTertiary')
    }

    It "HostViewModel contains no hex colour literal (the palette lives in UIColors.xaml)" {
        $script:VmText | Should -Not -Match '#[0-9A-Fa-f]{6}'
    }

    It "HostViewModel never converts colours itself (presenter resolves, VM holds)" {
        $script:VmText | Should -Not -Match 'ColorConverter'
    }

    It "UIColors.xaml defines every palette key the rows use" {
        $xamlText = Get-Content -LiteralPath $script:ColorsPath -Raw
        foreach ($key in $script:PaletteKeys) {
            $xamlText | Should -Match ('x:Key="{0}"' -f $key)
        }
    }

    It "SeedRowPalette resolves every key the rows use" {
        foreach ($key in $script:PaletteKeys) {
            $script:PresenterText | Should -Match ("'{0}'" -f $key)
        }
        $script:PresenterText | Should -Match 'SetPalette'
    }
}
