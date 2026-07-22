<#
    Regression guard for the dev/hosted startup path's C# helper compilation.

    Start-Donut.ps1 compiles the src/Launcher C# helpers with Add-Type when their
    types are not already resident (production compiles them into Donut.Launcher -
    which also HOSTS this script). The app once crashed at the class-graph parse
    with "Unable to find type [WindowChromeHelper]": every helper hid behind ONE
    guard type (ObservableObject), so any session with the MVVM types resident but
    a newer helper missing - an installed launcher built before that helper
    existed, or a console that had run an older tree - skipped the whole compile
    block and the first graph reference to the missing type killed startup.

    Rule: every helper type the class graph references must have its OWN
    `-as [type]` guard in Start-Donut.ps1, compiling only its own file.
#>

Describe "Start-Donut dev-path helper compilation" {

    BeforeAll {
        $script:StartDonut = Join-Path $PSScriptRoot '../../src/Start-Donut.ps1'
        $script:Raw = Get-Content $script:StartDonut -Raw
    }

    It "Start-Donut.ps1 parses cleanly" {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $StartDonut, [ref]$null, [ref]$errs)
        @($errs).Count | Should -Be 0
    }

    It "guards every graph-referenced helper type individually" {
        foreach ($type in @(
                'Donut.Mvvm.ObservableObject',
                'Donut.Mvvm.RelayCommand',
                'Donut.Interop.WindowChromeHelper',
                'Donut.Qr.QrCode',
                'Donut.Interop.HotkeyManager')) {
            $Raw | Should -Match ([regex]::Escape("'$type' -as [type]")) -Because (
                "$type must be compiled whenever it is missing, no matter which " +
                "other helper types are already resident in the session")
        }
    }

    It "compiles WindowChromeHelper.cs under its own guard, not another type's" {
        $Raw | Should -Match '(?s)Donut\.Interop\.WindowChromeHelper.{0,300}?WindowChromeHelper\.cs' -Because (
            "the helper must compile whenever ITS type is missing - riding another " +
            "type's guard is exactly what skipped it and crashed the graph parse")
    }
}
