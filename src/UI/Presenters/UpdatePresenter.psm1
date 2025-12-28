using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'
using module '.\LoginPresenter.psm1'
using module '.\DialogPresenter.psm1'

class UpdatePresenter {
    [SelfUpdateService]$Service
    [ResourceService]$Resources
    [DialogPresenter]$Dialog

    UpdatePresenter([ResourceService]$resources) {
        $this.Service = [SelfUpdateService]::new()
        $this.Resources = $resources
        $this.Dialog = [DialogPresenter]::new($resources)
    }

    # -------------------------------------------------------------------------
    # Main Entry Point
    # -------------------------------------------------------------------------

    [void] CheckAndPrompt() {
        $localVer = $this.Service.GetLocalVersion()
        $token = $this.Service.GetStoredToken()
        
        # If no token, prompt for login
        if ([string]::IsNullOrEmpty($token)) {
            $loginPresenter = [LoginPresenter]::new($this.Service, $this.Resources)
            if (-not $loginPresenter.ShowLogin()) { 
                Write-Host "Login cancelled or failed."
                return 
            }
            $token = $this.Service.GetStoredToken()
        }

        try {
            $release = $this.Service.GetLatestRelease($token)
            if (-not $release) { return }

            $remoteVer = [version]$release.tag_name
            
            if ($remoteVer -ne $localVer) {
                $this.ShowUpdateWindow($release, $localVer, $remoteVer)
            }
        }
        catch {
            Write-Host "Update check failed: $_"
        }
    }

    # -------------------------------------------------------------------------
    # Update UI
    # -------------------------------------------------------------------------

    [void] ShowUpdateWindow($Release, $LocalVer, $RemoteVer) {
        $isRollback = ($LocalVer -gt $RemoteVer)
        $result = $this.Dialog.ShowUpdatePrompt($LocalVer.ToString(), $RemoteVer.ToString(), $isRollback)
        
        if ($result) {
            $this.PerformUpdate($Release)
        }
    }

    [void] PerformUpdate($Release) {
        try {
            $asset = $this.Service.GetReleaseAsset($Release, '*.msi')
            if (-not $asset) { throw "No MSI asset found." }

            $token = $this.Service.GetStoredToken()
            $stage = Join-Path -Path $env:LOCALAPPDATA -ChildPath "DONUT"
            
            # Show progress? For now, just blocking call (UI might freeze, ideally async)
            # Since we are closing the update window before this, it's fine if it blocks briefly before app closes.
            
            $msiPath = $this.Service.DownloadAsset($token, $asset, $stage)
            
            # Verify Checksum
            $checksumAsset = $this.Service.GetReleaseAsset($Release, '*.sha256')
            if ($checksumAsset) {
                $checksumPath = $this.Service.DownloadAsset($token, $checksumAsset, $stage)
                $content = Get-Content $checksumPath -Raw
                $expectedHash = ($content -split '\s+')[0].Trim()
                
                if (-not $this.Service.VerifyFileHash($msiPath, $expectedHash)) {
                    throw "SHA-256 hash mismatch. Update aborted."
                }
            } else {
                Write-Warning "No checksum file found. Skipping verification."
            }

            $localVer = $this.Service.GetLocalVersion()
            $remoteVer = [version]$Release.tag_name
            $isRollback = ($localVer -gt $remoteVer)
            
            $this.Service.ApplyUpdate($msiPath, $isRollback, $this.Resources.SourceRoot)
            
            # Close the main app
            [System.Windows.Application]::Current.Shutdown()
        }
        catch {
            [System.Windows.MessageBox]::Show("Update Failed: $_", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
    }

    # -------------------------------------------------------------------------
    # Helpers
    # -------------------------------------------------------------------------
}
