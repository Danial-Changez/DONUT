# Load WPF assemblies first, then dot-source the actual tests
Add-Type -AssemblyName PresentationFramework -ErrorAction SilentlyContinue
Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue
Add-Type -AssemblyName WindowsBase -ErrorAction SilentlyContinue

. "$PSScriptRoot\ViewComposition.Integration.Internal.ps1"
