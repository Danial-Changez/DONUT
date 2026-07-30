using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'
using module '..\..\Core\DonutPaths.psm1'
using module '..\..\Core\LogService.psm1'
using module '.\LoginPresenter.psm1'
using module '.\DialogPresenter.psm1'

<#
.SYNOPSIS
    Checks for a newer release on startup and prompts to update or roll back.

.DESCRIPTION
    Uses SelfUpdateService to compare the installed version to the latest GitHub
    release, and on a difference shows the update window (via DialogPresenter),
    then downloads, verifies and applies the MSI (or rolls back to an older tag).
#>
class UpdatePresenter {
    [SelfUpdateService]$Service
    [ResourceService]$Resources
    [DialogPresenter]$Dialog
    [LogService]$Logger

    UpdatePresenter([SelfUpdateService]$service, [ResourceService]$resources) {
        $this.Service = $service
        $this.Resources = $resources
        $this.Logger = $resources.Logger
        $this.Dialog = [DialogPresenter]::new($resources)
    }

    # Runs sign-in (if needed) + the update check/prompt. Called after the main window is
    # already built + pool-warmed (see DonutApp), so it only gates showing it.
    [void] CheckAndPrompt() {
        $localVer = $this.Service.GetLocalVersion()
        $token = $this.Service.GetStoredToken()

        if ([string]::IsNullOrEmpty($token)) {
            $loginPresenter = [LoginPresenter]::new($this.Service, $this.Resources)
            if (-not $loginPresenter.ShowLogin()) {
                $this.Logger.LogInfo("Login cancelled or failed.")
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
            $this.Logger.LogException("Update check failed", $_)
        }
    }

    # --- Update UI ---

    [void] ShowUpdateWindow($Release, $LocalVer, $RemoteVer) {
        $isRollback = ($LocalVer -gt $RemoteVer)
        $result = $this.Dialog.ShowUpdatePrompt($LocalVer.ToString(), $RemoteVer.ToString(),
            $isRollback)

        if ($result) {
            $this.PerformUpdate($Release)
        }
    }

    [void] PerformUpdate($Release) {
        try {
            $asset = $this.Service.GetReleaseAsset($Release, '*.msi')
            if (-not $asset) { throw "No MSI asset found." }

            $token = $this.Service.GetStoredToken()
            $stage = [DonutPaths]::DataRoot()

            # Blocking download is acceptable here: the update window is already
            # closed and the app shuts down right after applying.
            $msiPath = $this.Service.DownloadAsset($token, $asset, $stage)

            $checksumAsset = $this.Service.GetReleaseAsset($Release, '*.sha256')
            if ($checksumAsset) {
                $checksumPath = $this.Service.DownloadAsset($token, $checksumAsset, $stage)
                $content = Get-Content $checksumPath -Raw
                $expectedHash = ($content -split '\s+')[0].Trim()

                if (-not $this.Service.VerifyFileHash($msiPath, $expectedHash)) {
                    throw "SHA-256 hash mismatch. Update aborted."
                }
            }
            else {
                $this.Logger.LogWarning("No checksum file found. Skipping verification.")
            }

            $localVer = $this.Service.GetLocalVersion()
            $remoteVer = [version]$Release.tag_name
            $isRollback = ($localVer -gt $remoteVer)

            $this.Service.ApplyUpdate($msiPath, $isRollback, $this.Resources.SourceRoot)

            [System.Windows.Application]::Current.Shutdown()
        }
        catch {
            # Themed alert (not a raw MessageBox) so the failure matches the app's dialogs;
            # ShowAlert falls back to Topmost when the main window isn't up yet.
            $this.Logger.LogException("Update failed", $_)
            $this.Dialog.ShowAlert('Update failed', "$_", @())
        }
    }
}
