<#
.SYNOPSIS
    Self-updates the DONUT application from GitHub Releases.

.DESCRIPTION
    Discovers the latest release, downloads and SHA-256 verifies the MSI, and
    hands off to InstallWorker.ps1 to install or roll back. Compares the
    installed version to the release tag to decide update vs. rollback vs. no-op.

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
        $uri = "https://api.github.com/repos/$($this.Owner)/$($this.Repo)/releases/latest"
        $headers = [SelfUpdateService]::Headers($Token, 'application/vnd.github.v3+json')
        # A cap, or a dead network hangs the deferred tray-surface check on the UI thread.
        return Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
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

    [version] GetLocalVersion() {
        # Registry first for MSI installs, with match criteria mirroring InstallWorker's.
        $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        if (Test-Path $regPath) {
            $subKeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue
            foreach ($key in $subKeys) {
                $app = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($app.DisplayName -like '*DONUT*' -and $app.Publisher -like '*Bakery*') {
                    if ($app.DisplayVersion) {
                        return [version]$app.DisplayVersion
                    }
                }
            }
        }

        # Fallback for dev/portable installs: the version file.
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

    [void] ApplyUpdate([string]$MsiPath, [bool]$IsRollback, [string]$SourceRoot) {
        $workerScript = Join-Path $SourceRoot "Scripts\InstallWorker.ps1"
        if (-not (Test-Path $workerScript)) { throw "InstallWorker.ps1 not found at $workerScript" }

        # Run the worker from the stage dir: the MSI replaces the source tree mid-install.
        $stageDir = Split-Path $MsiPath -Parent
        $tempWorker = Join-Path $stageDir "InstallWorker.ps1"
        Copy-Item -Path $workerScript -Destination $tempWorker -Force

        $argList = @(
            "-File `"$tempWorker`"",
            "-MsiPath `"$MsiPath`"",
            "-ProcessNameToClose `"DONUT`"",
            "-Passive"
        )

        if ($IsRollback) {
            $argList += "-Rollback"
        }

        Start-Process -FilePath "powershell.exe" `
                      -ArgumentList $argList `
                      -WindowStyle Hidden
    }
}
