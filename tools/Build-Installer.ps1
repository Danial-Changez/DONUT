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

.PARAMETER SkipSigning
    Build unsigned even when a signing certificate is available.

.EXAMPLE
    pwsh -File tools\Build-Installer.ps1 -Version 2.0.0
#>
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')]
    [string] $Version,
    [switch] $SkipSigning
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
$buildOutput = dotnet build (Join-Path $repo 'installer\Donut.Installer.wixproj') -c Release -v quiet -nologo `
    "-p:DonutVersion=$Version" "-p:StageDir=$stage" 2>&1
$buildOutput | Write-Output
if ($LASTEXITCODE -ne 0) { throw "MSI build failed with exit code $LASTEXITCODE." }
# Windows Installer policy (enterprise GPO, typically) can make WiX silently skip
# ICE validation - the build stays green and the MSI ships unvalidated. Surface it.
if ($buildOutput -match 'WIX1105') {
    Write-Warning ('ICE validation was skipped by system policy (WIX1105): this MSI was NOT ' +
        'validated on this machine. Package.wxs validates clean where policy allows; build ' +
        'on such a machine when changing the installer.')
}

$msi = Get-ChildItem (Join-Path $repo 'installer\bin') -Recurse -Filter 'DONUT.msi' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# --- Signing. Policy: this script NEVER creates or imports a certificate - it
# only reads one already provisioned in the user store through sanctioned
# channels. Until one exists, builds are unsigned by design. (signtool is needed
# because Set-AuthenticodeSignature cannot sign compound documents like MSI; it
# bootstraps from the Windows SDK BuildTools NuGet package into tools\.cache on
# first use, same pattern as ReportGenerator.) ---
$cert = if (-not $SkipSigning) {
    Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object Subject -eq 'CN=Danial Changez' |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}
if ($cert) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse `
        -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -match '\\x64\\' | Select-Object -First 1
    if (-not $signtool) {
        $toolDir = Join-Path $repo 'tools\.cache\signtool'
        $signtool = Get-ChildItem $toolDir -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object FullName -match '\\x64\\' | Select-Object -First 1
        if (-not $signtool) {
            Write-Host 'Fetching signtool (first run only)...' -ForegroundColor Cyan
            $nupkg = Join-Path $env:TEMP 'sdk-buildtools.nupkg.zip'
            Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools' `
                -OutFile $nupkg
            Expand-Archive $nupkg -DestinationPath $toolDir -Force
            Remove-Item $nupkg
            $signtool = Get-ChildItem $toolDir -Recurse -Filter signtool.exe |
                Where-Object FullName -match '\\x64\\' | Select-Object -First 1
        }
    }
    Write-Host "Signing as $($cert.Subject) ($($cert.Thumbprint))..." -ForegroundColor Cyan
    # Timestamp so the signature outlives the certificate; retry untimestamped when
    # the TSA is unreachable (an offline build should still produce a signed MSI).
    & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 /td SHA256 `
        /tr 'http://timestamp.digicert.com' $msi.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Timestamped signing failed (TSA unreachable?); signing without a timestamp.'
        & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 $msi.FullName
        if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
    }
}
else {
    Write-Host 'No signing certificate provisioned - building unsigned (expected until one is sanctioned).'
}

Write-Host "MSI built: $($msi.FullName)" -ForegroundColor Green
