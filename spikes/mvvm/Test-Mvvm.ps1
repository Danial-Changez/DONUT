<#
.SYNOPSIS
    Headless feasibility spike: can DONUT move from MVP to MVVM in PowerShell?

.DESCRIPTION
    Bootstraps WPF + a C# ObservableObject base, then runs Spike-Body.ps1, which
    exercises REAL WPF data bindings (no window shown) to answer three questions:
      1. Do PSCustomObjects support WPF binding + live change notification?
      2. Does a PowerShell view-model inheriting a C# INotifyPropertyChanged base
         update the UI when a property changes?
      3. Does an ObservableCollection bound to an ItemsControl auto-update the list?

    Run:  pwsh -Sta -File spikes/mvvm/Test-Mvvm.ps1
    (re-launches itself under STA if needed).
#>
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "Re-launching under STA for WPF..." -ForegroundColor Yellow
    & pwsh -Sta -NoProfile -File $PSCommandPath
    exit $LASTEXITCODE
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Compile the same ObservableObject base the real app would ship in Donut.Launcher.
Add-Type -TypeDefinition (Get-Content -Raw "$PSScriptRoot\ObservableObject.cs")

# Dot-source the body AFTER the base type exists, so the PS view-model class that
# inherits it resolves at parse time (mirrors Start-Donut -> DonutApp).
. "$PSScriptRoot\Spike-Body.ps1"
