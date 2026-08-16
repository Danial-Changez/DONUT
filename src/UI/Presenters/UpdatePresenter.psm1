using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Models\AppConfig.psm1'
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
    Uses SelfUpdateService to compare the installed version to the newest GitHub
    release on the configured channel (beta includes prereleases), and on a
    difference shows the update window (via DialogPresenter), then downloads,
    verifies and applies the MSI (or rolls back to an older tag).

.NOTES
    Any difference prompts, in either direction, so turning the beta toggle off on
    a machine running a prerelease offers the stable build as a rollback.

    Anonymous-first: the public upstream answers without auth, so a default install
    never sees a sign-in. Only when the repo refuses does the device-flow login
    appear, once, and the check retries with the stored token from then on.

    Which refusals are promptable: GitHub answers 404 for a private repo asked
    anonymously (a fork) and 401 for a dead stored token, and signing in fixes both.
    A 403 is the anonymous rate limit and an offline failure throws without a status,
    so neither prompts.
#>
class UpdatePresenter {
    [SelfUpdateService]$Service
    [ResourceService]$Resources
    [DialogPresenter]$Dialog
    [LogService]$Logger
    [AppConfig]$Config

    UpdatePresenter([SelfUpdateService]$service, [ResourceService]$resources, [AppConfig]$config) {
        $this.Service = $service
        $this.Resources = $resources
        $this.Config = $config
        $this.Logger = $resources.Logger
        $this.Dialog = [DialogPresenter]::new($resources)
    }

    # Runs the update check and prompt, after the main window is built and pool-warmed.
    # Anonymous-first, with a sign-in only when the repo refuses. See .NOTES.
    [void] CheckAndPrompt() {
        $localVer = $this.Service.GetLocalVersion()
        $token = $this.Service.GetStoredToken()
        # Read now, not at construction: the toggle may have been flipped this session.
        $beta = $this.Config.GetBetaUpdates()

        $release = $null
        try {
            $release = $this.Service.GetLatestRelease($token, $beta)
        } catch {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch {}
            # Only 404-anonymous and 401 are fixable by signing in. See .NOTES.
            $promptable = ($status -eq 404 -and [string]::IsNullOrEmpty($token)) -or
            ($status -eq 401)
            if (-not $promptable) {
                $this.Logger.LogException("Update check failed", $_)
                return
            }

            $loginPresenter = [LoginPresenter]::new($this.Service, $this.Resources)
            if (-not $loginPresenter.ShowLogin()) {
                $this.Logger.LogInfo("Login cancelled or failed.")
                return
            }
            $token = $this.Service.GetStoredToken()
            try {
                $release = $this.Service.GetLatestRelease($token, $beta)
            } catch {
                $this.Logger.LogException("Update check failed after sign-in", $_)
                return
            }
        }

        try {
            if (-not $release) { return }

            $remoteVer = [version]$release.tag_name.TrimStart('v')

            if ($remoteVer -ne $localVer) {
                $this.ShowUpdateWindow($release, $localVer, $remoteVer, $token)
            }
        } catch {
            $this.Logger.LogException("Update check failed", $_)
        }
    }

    # --- Update UI ---

    [void] ShowUpdateWindow($Release, $LocalVer, $RemoteVer, $token) {
        $isRollback = ($LocalVer -gt $RemoteVer)
        $result = $this.Dialog.ShowUpdatePrompt($LocalVer.ToString(), $RemoteVer.ToString(),
            $isRollback)

        if ($result) {
            $this.PerformUpdate($Release, $isRollback, $token)
        }
    }

    # The rollback verdict and token are the ones the prompt was built from, so what
    # the operator consented to is what runs, whatever a re-read would say now.
    [void] PerformUpdate($Release, [bool]$isRollback, $token) {
        try {
            $asset = $this.Service.GetReleaseAsset($Release, '*.msi')
            if (-not $asset) { throw "No MSI asset found." }

            $stage = [DonutPaths]::DataRoot()

            # A blocking download is fine here: the window is closed and the app exits after.
            $msiPath = $this.Service.DownloadAsset($token, $asset, $stage)

            $checksumAsset = $this.Service.GetReleaseAsset($Release, '*.sha256')
            if ($checksumAsset) {
                $checksumPath = $this.Service.DownloadAsset($token, $checksumAsset, $stage)
                $content = Get-Content $checksumPath -Raw
                $expectedHash = ($content -split '\s+')[0].Trim()

                if (-not $this.Service.VerifyFileHash($msiPath, $expectedHash)) {
                    throw "SHA-256 hash mismatch. Update aborted."
                }
            } else {
                $this.Logger.LogWarning("No checksum file found. Skipping verification.")
            }

            $this.Service.ApplyUpdate($msiPath, $isRollback, $this.Resources.SourceRoot)

            [System.Windows.Application]::Current.Shutdown()
        } catch {
            # Themed alert, not a raw MessageBox, so the failure matches the app's dialogs.
            $this.Logger.LogException("Update failed", $_)
            $this.Dialog.ShowAlert('Update Failed', "$_", @())
        }
    }
}
