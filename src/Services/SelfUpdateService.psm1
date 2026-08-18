<#
.SYNOPSIS
    Self-updates the DONUT application from GitHub Releases.

.DESCRIPTION
    Discovers the latest release, downloads and SHA-256 verifies the package, and
    hands off to InstallWorker.ps1 to install or roll back. Compares the
    installed version to the release tag to decide update vs. rollback vs. no-op.

    Which package depends on how this copy was installed. An MSI install takes the MSI
    and reads its version from the uninstall key; a zip install (tools/Install-Beta.ps1,
    a directory of its own outside Program Files) takes the zip and reads its version
    from the version.txt inside it, so an update never runs msiexec at all. A zip
    unpacks into a directory only administrators can write, so that apply asks for the
    rights msiexec would have prompted for, silent whenever DONUT already runs elevated.

    The default Owner/Repo is the public upstream, which answers anonymously -
    no sign-in involved. An org running a private fork points Owner/Repo at the
    fork and sets ClientId to its own GitHub App; the device flow (DPAPI-stored
    token) then authenticates every request.
#>
using module "..\Core\DonutPaths.psm1"
using module "..\Core\LogService.psm1"

class SelfUpdateService {
    [string]$ClientId = 'Your Github App Client ID'   # Only needed for a private fork.
    [string]$Scope = 'repo read:packages'
    [string]$TokenFile
    [string]$Owner = 'Danial-Changez'
    [string]$Repo = 'DONUT'
    [LogService]$Logger

    SelfUpdateService() {
        $this.Logger = [NullLogService]::new()
        $this.TokenFile = Join-Path ([DonutPaths]::ConfigDir()) "GitHub_Token.json"
    }

    SelfUpdateService([LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.TokenFile = Join-Path ([DonutPaths]::ConfigDir()) "GitHub_Token.json"
    }

    # --- Token management (DPAPI) ---

    [string] GetStoredToken() {
        if (-not (Test-Path $this.TokenFile)) { return $null }
        try {
            $bytes = [IO.File]::ReadAllBytes($this.TokenFile)
            $decrypted = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            $json = [Text.Encoding]::UTF8.GetString($decrypted)
            $data = $json | ConvertFrom-Json

            # Returned as-is, deliberately: no expiry check and no refresh.
            return $data.access_token
        } catch {
            $this.Logger.LogException("Failed to read stored token", $_)
            return $null
        }
    }

    [void] SaveToken([PSCustomObject]$TokenData) {
        $json = $TokenData | ConvertTo-Json -Depth 2
        $bytes = [Text.Encoding]::UTF8.GetBytes($json)
        $encrypted = [System.Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        $dir = [IO.Path]::GetDirectoryName($this.TokenFile)
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
        [IO.File]::WriteAllBytes($this.TokenFile, $encrypted)
    }

    # --- Device flow ---

    [PSCustomObject] InitiateDeviceFlow() {
        $body = @{
            client_id = $this.ClientId
            scope     = $this.Scope
        }
        $req = @{
            Uri        = 'https://github.com/login/device/code'
            Method     = 'Post'
            Body       = $body
            Headers    = @{ Accept = 'application/json' }
            TimeoutSec = 15
        }
        return Invoke-RestMethod @req
    }

    # Polls GitHub's device-flow token endpoint once. Status tells the caller what is
    # next: 'authorized' with a token, 'pending', 'slow_down' to back off, or 'error'.
    [PSCustomObject] PollForToken([string]$DeviceCode) {
        $body = @{
            client_id   = $this.ClientId
            device_code = $DeviceCode
            grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
        }
        try {
            $req = @{
                Uri        = 'https://github.com/login/oauth/access_token'
                Method     = 'Post'
                Body       = $body
                Headers    = @{ Accept = 'application/json' }
                TimeoutSec = 15
            }
            $response = Invoke-RestMethod @req

            if ($response.error) {
                $status = switch ($response.error) {
                    'authorization_pending' { 'pending' }
                    'slow_down' { 'slow_down' }
                    default { 'error' }
                }
                $err = if ($status -eq 'error') { $response.error } else { $null }
                return [PSCustomObject]@{
                    Status = $status; AccessToken = $null; TokenData = $null; Error = $err
                }
            }

            return [PSCustomObject]@{
                Status      = 'authorized'
                AccessToken = $response.access_token
                TokenData   = $response
                Error       = $null
            }
        } catch {
            $this.Logger.LogDebug("Device-flow token poll failed (will retry): $($_.Exception.Message)")
            return [PSCustomObject]@{
                Status = 'pending'; AccessToken = $null; TokenData = $null; Error = $null
            }
        }
    }

    # --- Release management ---

    # Authorization only when a token exists: the public upstream answers anonymously.
    hidden static [hashtable] Headers([string]$Token, [string]$Accept) {
        $h = @{ Accept = $Accept }
        if (-not [string]::IsNullOrEmpty($Token)) { $h['Authorization'] = "token $Token" }
        return $h
    }

    [PSCustomObject] GetLatestRelease([string]$Token) {
        return $this.GetLatestRelease($Token, $false)
    }

    # Beta follows the newest release of either kind, and GitHub's latest endpoint skips
    # prereleases by definition, so that channel takes the list's first non-draft entry.
    [PSCustomObject] GetLatestRelease([string]$Token, [bool]$IncludeBeta) {
        $releases = "https://api.github.com/repos/$($this.Owner)/$($this.Repo)/releases"
        $uri = if ($IncludeBeta) { "${releases}?per_page=10" } else { "$releases/latest" }
        $headers = [SelfUpdateService]::Headers($Token, 'application/vnd.github.v3+json')
        # A cap, or a dead network hangs the deferred tray-surface check on the UI thread.
        $result = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
        if (-not $IncludeBeta) { return $result }
        return ($result | Where-Object { -not $_.draft } | Select-Object -First 1)
    }

    [PSCustomObject] GetReleaseAsset([PSCustomObject]$Release, [string]$Pattern) {
        return ($Release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1)
    }

    [string] DownloadAsset([string]$Token, [PSCustomObject]$Asset, [string]$DestDir) {
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir | Out-Null }

        $destPath = Join-Path $DestDir $Asset.name
        $headers = [SelfUpdateService]::Headers($Token, 'application/octet-stream')

        # Generous, since this is the MSI itself, but no longer indefinite.
        Invoke-RestMethod -Uri $Asset.url `
                          -Headers $headers `
                          -OutFile $destPath `
                          -TimeoutSec 300
        return $destPath
    }

    # --- Install shape ---

    # The directory this copy runs from, or '' on the dev path where the host is pwsh.
    # Overridable so tests can place the exe without touching the real process.
    [string] InstallRoot() {
        $exe = [Environment]::ProcessPath
        if (-not $exe -or [IO.Path]::GetFileName($exe) -ine 'DONUT.exe') { return '' }
        return [IO.Path]::GetDirectoryName($exe)
    }

    # A zip install has no uninstall entry, so the registered location is what tells the
    # two apart: running inside it means msiexec owns this copy, outside means the zip does.
    [bool] IsPortable() {
        $root = $this.InstallRoot()
        if (-not $root) { return $false }
        $registered = $this.RegisteredInstall()
        if (-not $registered -or -not $registered.Location) { return $true }
        return -not $root.StartsWith($registered.Location, [StringComparison]::OrdinalIgnoreCase)
    }

    # The uninstall-key entry for an MSI install, match criteria mirroring InstallWorker's.
    hidden [PSCustomObject] RegisteredInstall() {
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        if (-not (Test-Path $regPath)) { return $null }

        $subKeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
        foreach ($key in $subKeys) {
            $app = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
            if ($app.DisplayName -like '*DONUT*' -and $app.Publisher -like '*Bakery*') {
                return [PSCustomObject]@{
                    Location = [string]$app.InstallLocation
                    Version  = [string]$app.DisplayVersion
                }
            }
        }
        return $null
    }

    # The version a zip install carries: the release build writes VERSION into the
    # package, so the update replaces it and nothing keeps a separate marker in step.
    hidden [version] PackagedVersion() {
        $root = $this.InstallRoot()
        if (-not $root) { return $null }
        $file = Join-Path $root 'VERSION'
        if (-not (Test-Path $file)) { return $null }
        try {
            return [version](Get-Content $file -Raw).Trim()
        } catch {
            return $null
        }
    }

    [version] GetLocalVersion() {
        # The exe first when the zip owns this copy: the uninstall key belongs to a
        # different install then, and reading it would compare against someone else's build.
        if ($this.IsPortable()) {
            $packaged = $this.PackagedVersion()
            if ($packaged) { return $packaged }
        }

        $registered = $this.RegisteredInstall()
        if ($registered -and $registered.Version) { return [version]$registered.Version }

        # Fallback for a dev checkout, which has neither an uninstall key nor a package.
        $verFile = Join-Path ([DonutPaths]::DataRoot()) "version.txt"
        if (Test-Path $verFile) {
            return [version](Get-Content $verFile -Raw).Trim()
        }

        return [version]"0.0.0.0"
    }

    [bool] VerifyFileHash([string]$FilePath, [string]$ExpectedHash) {
        if (-not (Test-Path $FilePath)) { return $false }
        $hash = Get-FileHash -Path $FilePath -Algorithm SHA256
        return ($hash.Hash -eq $ExpectedHash)
    }

    # PackagePath is the MSI or the zip, and which one decides how the worker installs it.
    # The zip branch asks for the rights msiexec would have prompted for. See .DESCRIPTION.
    [void] ApplyUpdate([string]$PackagePath, [bool]$IsRollback, [string]$SourceRoot) {
        $workerScript = Join-Path $SourceRoot "Scripts\InstallWorker.ps1"
        if (-not (Test-Path $workerScript)) { throw "InstallWorker.ps1 not found at $workerScript" }

        # Run the worker from the stage dir: the package replaces the source tree mid-install.
        $stageDir = Split-Path $PackagePath -Parent
        $tempWorker = Join-Path $stageDir "InstallWorker.ps1"
        Copy-Item -Path $workerScript -Destination $tempWorker -Force

        $isZip = $PackagePath -like '*.zip'
        $argList = @(
            "-File `"$tempWorker`"",
            "-ProcessNameToClose `"DONUT`"",
            "-Passive"
        )

        if ($isZip) {
            $argList += "-ZipPath `"$PackagePath`""
            $argList += "-InstallDir `"$($this.InstallRoot())`""
        } else {
            $argList += "-MsiPath `"$PackagePath`""
        }

        if ($IsRollback) {
            $argList += "-Rollback"
        }

        if ($isZip) {
            Start-Process -FilePath "powershell.exe" `
                          -ArgumentList $argList `
                          -Verb RunAs `
                          -WindowStyle Hidden
        } else {
            Start-Process -FilePath "powershell.exe" `
                          -ArgumentList $argList `
                          -WindowStyle Hidden
        }
    }
}
