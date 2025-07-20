# Updater script for DONUT, checks for updates using manifest.json, updates if needed, then launches the main app
param(
    [string]$manifestFile = "\\cgic.ca\GPHFILES\SCRATCH\DC\manifest.json",
    [string]$shareRoot = "\\cgic.ca\GPHFILES\SCRATCH\DC"
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ImportXaml.psm1')
$ErrorActionPreference = 'Stop'

# Read local version from registry
Function Get-InstalledDisplayVersion {
    $uninstallPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
    if (Test-Path $uninstallPath) {
        $subKeys = Get-ChildItem -Path $uninstallPath -ErrorAction SilentlyContinue
        foreach ($subKey in $subKeys) {
            try {
                $app = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                if ($app.DisplayName -like "*DONUT*" -and $app.Publisher -like "*Co-operators*") {
                    return $app.DisplayVersion
                    Write-Host "Found DONUT version: $($app.DisplayVersion)"
                }
            } 
            catch {}
        }
    }
    # Default to 1.0.0.0, so we always update worst case
    return '1.0.0.0'
}

# Compare versions
Function Compare-Version($v1, $v2) {
    [version]$ver1 = $v1
    [version]$ver2 = $v2
    return $ver1.CompareTo($ver2)
}

# Update registry entries
Function Update-RegistryVersion {
    param(
        [string]$Version,
        [string]$InstallDate
    )
    try {
        $uninstallPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
        if (Test-Path $uninstallPath) {
            $subKeys = Get-ChildItem -Path $uninstallPath -ErrorAction SilentlyContinue
            
            # Look for the correct subkey for DONUT
            foreach ($subKey in $subKeys) {
                try {
                    $app = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
                    $isDonut = $false
                    if ($app.DisplayName -like "*DONUT*") { $isDonut = $true }
                    if ($app.InstallLocation -like "*DONUT*") { $isDonut = $true }
                    if ($app.Publisher -like "*Co-operators*") { $isDonut = $true }
                    if ($isDonut) {
                        # Update the version and install date
                        Set-ItemProperty -Path $subKey.PSPath -Name "DisplayVersion" -Value $Version -ErrorAction SilentlyContinue
                        Set-ItemProperty -Path $subKey.PSPath -Name "InstallDate" -Value $InstallDate -ErrorAction SilentlyContinue
                        if ($app.PSObject.Properties.Name -contains "Version") {
                            Set-ItemProperty -Path $subKey.PSPath -Name "Version" -Value $Version -ErrorAction SilentlyContinue
                        }                        
                    }
                }
                catch {}
            }
        }
    }
    catch {
        Write-Host "Error updating registry version: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Function Invoke-Update {
    # Only update if local and remote versions differ
    if (Compare-Version $localVersion $remoteVersion -ne 0) {
        foreach ($file in $manifest.files) {
            $src = Join-Path $shareRoot $file.path
            $dst = Join-Path $PSScriptRoot '..' $file.path
            Copy-Item $src $dst -Force
            
            # Verify hash if present
            if ($file.hash) {
                $localHash = (Get-FileHash $dst -Algorithm SHA256).Hash
                if ($localHash -ne $file.hash) {
                    Write-Warning "Hash mismatch for $($file.path)! Retrying copy..."

                    # Try copying again
                    Remove-Item $dst -Force -ErrorAction SilentlyContinue
                    Copy-Item $src $dst -Force
                    $localHash = (Get-FileHash $dst -Algorithm SHA256).Hash
                    if ($localHash -ne $file.hash) {
                        Write-Error "Hash mismatch for $($file.path) after retry!"
                        exit 2
                    }
                }
            }
        }

        # Update the version and install date in registry
        $installDate = $manifest.releaseDate -replace '-', ''
        Update-RegistryVersion -Version $remoteVersion -InstallDate $installDate
    }
}

$localVersion = Get-InstalledDisplayVersion
$window = Import-Xaml '..\Views\Update.xaml'

# Read manifest
if (Test-Path $manifestFile) {
    $manifest = Get-Content $manifestFile -Raw | ConvertFrom-Json
    $remoteVersion = $manifest.version
}
else {
    Write-Host "[ERROR] Manifest not found: $manifestFile" -ForegroundColor Red
    exit 1
}

# Merge all resource dictionaries from the Styles folder
$stylesPath = Join-Path $PSScriptRoot '..\Styles'
Get-ChildItem -Path $stylesPath -Filter '*.xaml' | ForEach-Object {
    $styleStream = [System.IO.File]::OpenRead($_.FullName)
    try {
        $styleDict = [Windows.Markup.XamlReader]::Load($styleStream)
        $window.Resources.MergedDictionaries.Add($styleDict)
    }
    catch {
        Write-Host "[ERROR] Failed to load style: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        $styleStream.Close()
    }
}

# PopUp logic
if (Compare-Version $localVersion $remoteVersion -lt 0) {
    $btnNow = $window.FindName('btnNow')
    $btnLater = $window.FindName('btnLater')
    $btnClose = $window.FindName('btnClose')
    $btnMinimize = $window.FindName('btnMinimize')
    $panelControlBar = $window.FindName('panelControlBar')

    # Update Now/Later logic
    $btnNow.Add_Click({
            Invoke-Update
            $window.Close()
        })
    $btnLater.Add_Click({
            $window.Close()
        })

    # Control bar logic (close, minimize, drag)
    if ($btnClose) {
        $btnClose.Add_Click({
                try { $window.Close() } catch {}
            })
    }
    if ($btnMinimize) {
        $btnMinimize.Add_Click({
                try { $window.WindowState = 'Minimized' } catch {}
            })
    }
    if ($panelControlBar) {
        $panelControlBar.Add_MouseLeftButtonDown({
                try { $window.DragMove() } catch {}
            })
    }

    $null = $window.ShowDialog()
}