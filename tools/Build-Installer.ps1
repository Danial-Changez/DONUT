<#
.SYNOPSIS
    Builds DONUT.msi: publish the launcher, stage the payload, build the WiX project.

.DESCRIPTION
    One command from repo root to a shippable MSI. Publishes Donut.Launcher
    (framework-dependent; targets need the .NET Desktop Runtime, as documented in
    installation.md), stages the publish output with the exe renamed to DONUT.exe
    (the bin\x64\DONUT\DONUT.exe path InstallWorker relaunches) and pdbs dropped,
    then builds installer\Donut.Installer.wixproj - the WiX SDK restores itself
    from NuGet, so plain dotnet is the only prerequisite.

.PARAMETER Version
    MSI ProductVersion (x.y.z). SelfUpdateService compares this DisplayVersion
    against GitHub release tags, so use the release's version.

.EXAMPLE
    pwsh -File tools\Build-Installer.ps1 -Version 1.4.0
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

Write-Host "Publishing Donut.Launcher..." -ForegroundColor Cyan
dotnet publish (Join-Path $repo 'src\Launcher\Donut.Launcher.csproj') -c Release -v quiet -nologo
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

$publish = Get-ChildItem (Join-Path $repo 'src\Launcher\bin\Release') -Recurse -Directory |
    Where-Object Name -eq 'publish' | Select-Object -First 1
if (-not $publish) { throw 'Publish output not found.' }

# Stage: fresh copy with the exe under its installed name and no debug symbols.
$stage = Join-Path $repo 'installer\obj\stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item $publish.FullName $stage -Recurse
Get-ChildItem $stage -Recurse -Filter '*.pdb' | Remove-Item
Rename-Item (Join-Path $stage 'Donut.Launcher.exe') 'DONUT.exe'

# WiX writes the .msi before ICE validation runs, so a failed build can leave a
# stale artifact behind that a later run would report as freshly built (the output
# may sit under a culture subfolder, hence the recursive sweep).
if (Test-Path (Join-Path $repo 'installer\bin')) {
    Get-ChildItem (Join-Path $repo 'installer\bin') -Recurse -Filter 'DONUT.msi' | Remove-Item -Force
}

Write-Host "Building the MSI..." -ForegroundColor Cyan
# Quoted as one token: the checkout path may carry spaces ("VS Programs"), and an
# unquoted -p value truncates at the first one.
dotnet build (Join-Path $repo 'installer\Donut.Installer.wixproj') -c Release -v quiet -nologo `
    "-p:DonutVersion=$Version" "-p:StageDir=$stage"
if ($LASTEXITCODE -ne 0) { throw "MSI build failed with exit code $LASTEXITCODE." }

$msi = Get-ChildItem (Join-Path $repo 'installer\bin') -Recurse -Filter 'DONUT.msi' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host "MSI built: $($msi.FullName)" -ForegroundColor Green
