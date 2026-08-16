# Load WPF and the Donut.Mvvm base types before the tests' `using module` graph parses.
. "$PSScriptRoot\..\Helpers\Import-UiTypes.ps1"

. "$PSScriptRoot\InventoryPresenter.Tests.Internal.ps1"
