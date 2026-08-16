<#
.SYNOPSIS
    Builds DONUT.msi: publish the launcher, stage the payload, build the WiX project.

.DESCRIPTION
    One command from repo root to a shippable MSI. Publishes Donut.Launcher
    self-contained (the .NET runtime ships inside the MSI, so operator machines
    need no runtime install), stages the publish output with the exe renamed to
    DONUT.exe (the bin\x64\DONUT\DONUT.exe path InstallWorker relaunches) and pdbs
    dropped, then builds installer\Donut.Installer.wixproj - the WiX SDK restores
    itself from NuGet, so plain dotnet is the only prerequisite.

.PARAMETER Version
    MSI ProductVersion (x.y.z). SelfUpdateService compares this DisplayVersion
    against GitHub release tags, so use the release's version.

.PARAMETER SkipSigning
    Build unsigned even when a signing certificate is available.

.NOTES
    Signing policy: this script never creates or imports a certificate. It only
    reads one already provisioned in the user store through sanctioned channels,
    so builds are unsigned by design until one exists. signtool is required
    because Set-AuthenticodeSignature cannot sign compound documents like MSI,
    and it bootstraps from the Windows SDK BuildTools NuGet package into
    tools\.cache on first use, the same pattern as ReportGenerator.

    WiX writes the .msi before ICE validation runs, so a failed build can leave a
    stale artifact that a later run would report as freshly built. The output may
    sit under a culture subfolder, so the pre-build sweep is recursive.

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
# Explicit -o: a recursive search could pick up a stale publish from an earlier build.
$publish = Join-Path $repo 'installer\obj\publish'
if (Test-Path $publish) { Remove-Item $publish -Recurse -Force }
dotnet publish (Join-Path $repo 'src\Launcher\Donut.Launcher.csproj') -c Release -v quiet -nologo `
    -r win-x64 --self-contained true -o $publish
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed with exit code $LASTEXITCODE." }

$stage = Join-Path $repo 'installer\obj\stage'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
Copy-Item $publish $stage -Recurse
Get-ChildItem $stage -Recurse -Filter '*.pdb' | Remove-Item
Rename-Item (Join-Path $stage 'Donut.Launcher.exe') 'DONUT.exe'

# WiX writes the .msi before ICE validation, so a failed build leaves one. See .NOTES.
if (Test-Path (Join-Path $repo 'installer\bin')) {
    Get-ChildItem (Join-Path $repo 'installer\bin') -Recurse -Filter 'DONUT.msi' | Remove-Item -Force
}

Write-Host "Building the MSI..." -ForegroundColor Cyan
# Quoted as one token: an unquoted -p value truncates at the first space in the path.
$buildOutput = dotnet build (Join-Path $repo 'installer\Donut.Installer.wixproj') -c Release -v quiet -nologo `
    "-p:DonutVersion=$Version" "-p:StageDir=$stage" 2>&1
$buildOutput | Write-Output
if ($LASTEXITCODE -ne 0) { throw "MSI build failed with exit code $LASTEXITCODE." }
# Policy can make WiX silently skip ICE validation, shipping an unvalidated MSI.
if ($buildOutput -match 'WIX1105') {
    Write-Warning ('ICE validation was skipped by system policy (WIX1105): this MSI was NOT ' +
        'validated on this machine. Package.wxs validates clean where policy allows; build ' +
        'on such a machine when changing the installer.')
}

$msi = Get-ChildItem (Join-Path $repo 'installer\bin') -Recurse -Filter 'DONUT.msi' |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1

# --- Signing ---
$cert = if (-not $SkipSigning) {
    Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
        Where-Object Subject -EQ 'CN=Danial Changez' |
        Sort-Object NotAfter -Descending | Select-Object -First 1
}
if ($cert) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Recurse `
        -Filter signtool.exe -ErrorAction SilentlyContinue |
        Where-Object FullName -Match '\\x64\\' | Select-Object -First 1
    if (-not $signtool) {
        $toolDir = Join-Path $repo 'tools\.cache\signtool'
        $signtool = Get-ChildItem $toolDir -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue |
            Where-Object FullName -Match '\\x64\\' | Select-Object -First 1
        if (-not $signtool) {
            Write-Host 'Fetching signtool (first run only)...' -ForegroundColor Cyan
            $nupkg = Join-Path $env:TEMP 'sdk-buildtools.nupkg.zip'
            Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools' `
                -OutFile $nupkg
            Expand-Archive $nupkg -DestinationPath $toolDir -Force
            Remove-Item $nupkg
            $signtool = Get-ChildItem $toolDir -Recurse -Filter signtool.exe |
                Where-Object FullName -Match '\\x64\\' | Select-Object -First 1
        }
    }
    Write-Host "Signing as $($cert.Subject) ($($cert.Thumbprint))..." -ForegroundColor Cyan
    # Timestamp so the signature outlives the certificate, retrying bare when the TSA is down.
    & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 /td SHA256 `
        /tr 'http://timestamp.digicert.com' $msi.FullName
    if ($LASTEXITCODE -ne 0) {
        Write-Warning 'Timestamped signing failed (TSA unreachable?); signing without a timestamp.'
        & $signtool.FullName sign /sha1 $cert.Thumbprint /fd SHA256 $msi.FullName
        if ($LASTEXITCODE -ne 0) { throw "signtool failed with exit code $LASTEXITCODE." }
    }
} else {
    Write-Host 'No signing certificate provisioned - building unsigned (expected until one is sanctioned).'
}

Write-Host "MSI built: $($msi.FullName)" -ForegroundColor Green
