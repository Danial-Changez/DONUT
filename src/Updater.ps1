# Updater script for DONUT, checks for updates using manifest.json and version.txt, updates if needed, then launches the main app

$ErrorActionPreference = 'Stop'

# Paths
$versionFile = Join-Path -Path $PSScriptRoot -ChildPath '..\res\version.txt'
# $manifestFile = '\\cgic.ca\gphfiles\TPSFiles\Support-Applications\DONUT\Development\manifest.json'
# $sharedRoot = '\\cgic.ca\gphfiles\TPSFiles\Support-Applications\DONUT\Development'
$manifestFile = '\\cgic.ca\GPHFILES\SCRATCH\DC\manifest.json'
$sharedRoot = '\\cgic.ca\GPHFILES\SCRATCH\DC'

# Read local version
if (Test-Path $versionFile) {
    $localVersion = (Get-Content $versionFile -Raw).Trim()
}
else {
    $localVersion = '1.0.0'
}

# Read manifest
if (Test-Path $manifestFile) {
    $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
    $remoteVersion = $manifest.version
}
else {
    Write-Host "[ERROR] Manifest not found: $manifestFile" -ForegroundColor Red
    exit 1
}

# Compare versions
Function Compare-Version($v1, $v2) {
    [version]$ver1 = $v1
    [version]$ver2 = $v2
    return $ver1.CompareTo($ver2)
}

if (Compare-Version $localVersion $remoteVersion -lt 0) {
    Write-Host "Updating application from $localVersion to $remoteVersion..." -ForegroundColor Yellow
    foreach ($file in $manifest.files) {
        $src = Join-Path $sharedRoot $file.path
        $dst = Join-Path $PSScriptRoot '..' $file.path
        Copy-Item $src $dst -Force
        
        # Verify hash if present
        if ($file.hash) {
            $localHash = (Get-FileHash $dst -Algorithm SHA256).Hash
            if ($localHash -ne $file.hash) {
                Write-Host "[ERROR] Hash mismatch for $($file.path)!" -ForegroundColor Red
                Write-Host "Expected: $($file.hash)" -ForegroundColor Red
                Write-Host "Actual:   $localHash" -ForegroundColor Red
                exit 2
            }
        }
    }
    Set-Content $versionFile $remoteVersion
    Write-Host "Update complete."
}
else {
    Write-Host "Application is up to date. Version: $localVersion"
}