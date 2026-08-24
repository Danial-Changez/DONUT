# HostViewModel carries WPF Brush fields and the Donut.Mvvm base, so both load before
# the `using module` graph parses (the helper guards per type, so it composes with the rest).
. "$PSScriptRoot\..\Helpers\Import-UiTypes.ps1"

. "$PSScriptRoot\HostViewModel.Tests.Internal.ps1"
