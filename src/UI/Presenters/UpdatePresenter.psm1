using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Models\AppConfig.psm1'
using module '..\..\Core\ConfigManager.psm1'
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'
using module '..\..\Core\DonutPaths.psm1'
using module '..\..\Core\LogService.psm1'
using module '.\LoginPresenter.psm1'
using module '.\DialogPresenter.psm1'
using module '.\ToastService.psm1'

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
    a machine running a prerelease offers the stable build as a rollback. Auto-update
    covers the forward direction only: a rollback is a decision, not a version bump.

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
    [ConfigManager]$ConfigManager

    # Assigned after MainPresenter builds it, since this presenter is constructed first.
    [ToastService]$Toasts

    UpdatePresenter(
        [SelfUpdateService]$service,
        [ResourceService]$resources,
        [AppConfig]$config,
        [ConfigManager]$configManager
    ) {
        $this.Service = $service
        $this.Resources = $resources
        $this.Config = $config
        $this.ConfigManager = $configManager
        $this.Logger = $resources.Logger
        $this.Dialog = [DialogPresenter]::new($resources)
    }

    # Runs the update check and prompt, after the main window is built and pool-warmed.
    # Anonymous-first, with a sign-in only when the repo refuses. See .NOTES.
    [void] CheckAndPrompt() {
        $localVer = $this.Service.GetLocalVersion()
        $this.ReportUpdateOutcome($localVer)
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

    # The install ran with DONUT closed and nothing on screen, so the relaunched copy
    # is the one that says where it landed.
    hidden [void] ReportUpdateOutcome([version]$localVer) {
        $target = $this.Service.TakePendingUpdate()
        if (-not $target) { return }
        if ($localVer -eq $target) {
            $this.Logger.LogInfo("Updated to v$target.")
            if ($this.Toasts) { $this.Toasts.ShowSuccess('Updated', "DONUT is now v$target.") }
            return
        }
        $this.Logger.LogWarning("The update to v$target did not complete; this is v$localVer.")
        if ($this.Toasts) {
            $this.Toasts.ShowWarning('Update Incomplete', "Still on v$localVer, expected v$target.")
        }
    }

    # ponytail: 300ms pump so a toast paints before the blocking download; go async for a real bar.
    hidden [void] PaintNow() {
        $until = [datetime]::UtcNow.AddMilliseconds(300)
        while ([datetime]::UtcNow -lt $until) {
            [Dispatcher]::CurrentDispatcher.Invoke([action] {}, [DispatcherPriority]::Background)
            Start-Sleep -Milliseconds 16
        }
    }

    # --- Update UI ---

    [void] ShowUpdateWindow($Release, $LocalVer, $RemoteVer, $token) {
        $isRollback = ($LocalVer -gt $RemoteVer)

        # Set before applying, since the apply closes the app and nothing saves after it.
        if (-not $isRollback -and $this.Config.GetAutoUpdate()) {
            $this.Logger.LogInfo("Auto-update is on, installing $RemoteVer without asking.")
            $this.PerformUpdate($Release, $isRollback, $token)
            return
        }

        # The release page, not the notes: nothing here renders unbounded markdown.
        $answer = $this.Dialog.ShowUpdatePrompt($LocalVer.ToString(), $RemoteVer.ToString(),
            $isRollback, [string]$Release.html_url)
        if (-not $answer.Confirmed) { return }

        if ($answer.Remember) { $this.PersistAutoUpdate() }
        $this.PerformUpdate($Release, $isRollback, $token)
    }

    # The prompt's checkbox, saved the way Settings would have saved the same toggle.
    hidden [void] PersistAutoUpdate() {
        try {
            $this.Config.SetSetting('autoUpdate', $true)
            $this.ConfigManager.SaveConfig($this.Config)
        } catch {
            $this.Logger.LogException("Could not save the auto-update choice", $_)
        }
    }

    # The rollback verdict and token are the ones the prompt was built from, so what
    # the operator consented to is what runs, whatever a re-read would say now.
    [void] PerformUpdate($Release, [bool]$isRollback, $token) {
        try {
            # The package this copy can actually install: msiexec owns one, the zip the other.
            $pattern = if ($this.Service.IsPortable()) { '*.zip' } else { '*.msi' }
            $asset = $this.Service.GetReleaseAsset($Release, $pattern)
            if (-not $asset) { throw "This release publishes no $pattern asset." }

            $stage = [DonutPaths]::DataRoot()
            $target = [version]$Release.tag_name.TrimStart('v')

            # A blocking download is fine here: the window is closed and the app exits after.
            if ($this.Toasts) {
                $this.Toasts.ShowInfo('Updating', "Downloading DONUT v$target…")
                $this.PaintNow()
            }
            $packagePath = $this.Service.DownloadAsset($token, $asset, $stage)

            # By name, not by pattern: the release carries a checksum for each package.
            $checksumAsset = $this.Service.GetReleaseAsset($Release, "$($asset.name).sha256")
            if ($checksumAsset) {
                $checksumPath = $this.Service.DownloadAsset($token, $checksumAsset, $stage)
                $content = Get-Content $checksumPath -Raw
                $expectedHash = ($content -split '\s+')[0].Trim()

                if (-not $this.Service.VerifyFileHash($packagePath, $expectedHash)) {
                    throw "SHA-256 hash mismatch. Update aborted."
                }
            } else {
                $this.Logger.LogWarning("No checksum file found. Skipping verification.")
            }

            # Recorded first: after this the app closes, and the relaunch reports the outcome.
            $this.Service.MarkPendingUpdate($target)
            $this.Service.ApplyUpdate($packagePath, $isRollback, $this.Resources.SourceRoot)

            [System.Windows.Application]::Current.Shutdown()
        } catch {
            $this.Logger.LogException("Update failed", $_)
            # Reported, not blocked: nothing installed, so there is no decision to make.
            if ($this.Toasts) { $this.Toasts.ShowError('Update Failed', $_.Exception.Message) }
        }
    }
}
