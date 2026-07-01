using namespace System.Windows
using namespace System.Windows.Threading
using module '..\..\Services\SelfUpdateService.psm1'
using module '..\..\Services\ResourceService.psm1'
using module '..\..\Core\LogService.psm1'
using module '..\..\Core\RunspaceManager.psm1'
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

    # Background-check state: the read-only discovery runs on the runspace pool and is
    # polled on the dispatcher, so startup never blocks on the GitHub round-trip.
    [DispatcherTimer] $CheckTimer
    hidden [object]   $CheckPs
    hidden [object]   $CheckHandle
    hidden [bool]     $CheckStarted = $false

    UpdatePresenter([SelfUpdateService]$service, [ResourceService]$resources) {
        $this.Service = $service
        $this.Resources = $resources
        $this.Logger = $resources.Logger
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

    # -------------------------------------------------------------------------
    # Background check (window shows first; GitHub round-trip runs on the pool)
    # -------------------------------------------------------------------------

    # One-shot: kick the read-only discovery on the runspace pool, then poll it on the
    # dispatcher. Called after the main window renders, so startup never blocks on the
    # GitHub round-trip. Safe to call more than once (Window.ContentRendered can refire).
    [void] StartBackgroundCheck() {
        if ($this.CheckStarted) { return }
        $this.CheckStarted = $true
        $this.KickCheck()
    }

    hidden [void] KickCheck() {
        try {
            $worker = Join-Path $this.Resources.SourceRoot 'Scripts\UpdateCheckWorker.ps1'
            $this.CheckPs = [System.Management.Automation.PowerShell]::Create()
            $this.CheckPs.RunspacePool = [RunspaceManager]::GetPool()
            $this.CheckPs.AddCommand($worker) | Out-Null
            $this.CheckHandle = $this.CheckPs.BeginInvoke()

            if (-not $this.CheckTimer) {
                $presenter = $this
                $this.CheckTimer = [DispatcherTimer]::new()
                $this.CheckTimer.Interval = [TimeSpan]::FromMilliseconds(200)
                $this.CheckTimer.Add_Tick({ $presenter.PollCheck() }.GetNewClosure())
            }
            $this.CheckTimer.Start()
        }
        catch {
            $this.Logger.LogException("Background update check could not start", $_)
        }
    }

    # Poll the pool job; when it lands, dispose it and act on the result (UI thread).
    [void] PollCheck() {
        if ($null -eq $this.CheckHandle -or -not $this.CheckHandle.IsCompleted) { return }
        $this.CheckTimer.Stop()

        $result = $null
        try { $result = @($this.CheckPs.EndInvoke($this.CheckHandle)) | Select-Object -Last 1 }
        catch { $this.Logger.LogException("Update check failed", $_) }
        try { $this.CheckPs.Dispose() } catch { }
        $this.CheckPs = $null
        $this.CheckHandle = $null

        if ($result -is [hashtable]) { $this.HandleResult($result) }
    }

    # Acts on the worker's result on the dispatcher: log in if there's no token (then
    # re-check), otherwise compare versions and prompt. Modals are safe here.
    hidden [void] HandleResult([hashtable]$result) {
        if ($result.ContainsKey('Error') -and $result.Error) {
            $this.Logger.LogError("Update check: $($result.Error)")
            return
        }

        if (-not $result.HasToken) {
            $loginPresenter = [LoginPresenter]::new($this.Service, $this.Resources)
            if ($loginPresenter.ShowLogin()) {
                $this.KickCheck()   # got a token now - re-run discovery on the pool
            } else {
                $this.Logger.LogInfo("Login cancelled or failed.")
            }
            return
        }

        if (-not $result.Release) { return }

        try {
            $remoteVer = [version]$result.Release.tag_name
            $localVer = if ($result.LocalVersion) { [version]$result.LocalVersion } else { [version]'0.0.0.0' }
            if ($remoteVer -ne $localVer) {
                $this.ShowUpdateWindow($result.Release, $localVer, $remoteVer)
            }
        }
        catch {
            $this.Logger.LogException("Update version comparison failed", $_)
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
                $this.Logger.LogWarning("No checksum file found. Skipping verification.")
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
}
