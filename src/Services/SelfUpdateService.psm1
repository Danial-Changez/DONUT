<#
.SYNOPSIS
    Self-updates the DONUT application from GitHub Releases.

.DESCRIPTION
    Authenticates via a GitHub App device flow (DPAPI-encrypted token), discovers
    the latest release, downloads and SHA-256 verifies the MSI, and hands off to
    InstallWorker.ps1 to install or roll back. Compares the installed version to
    the release tag to decide update vs. rollback vs. no-op.
#>
using module "..\Core\LogService.psm1"

class SelfUpdateService {
    [string]$ClientId = 'Your Github App Client ID'
    [string]$Scope = 'repo read:packages'
    [string]$TokenFile
    [string]$Owner = 'dania-net'
    [string]$Repo = 'DONUT'
    [LogService]$Logger

    SelfUpdateService() {
        $this.Logger = [NullLogService]::new()
        $this.TokenFile = Join-Path -Path $env:LOCALAPPDATA -ChildPath "DONUT\config\GitHub_Token.json"
    }

    SelfUpdateService([LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
        $this.TokenFile = Join-Path -Path $env:LOCALAPPDATA -ChildPath "DONUT\config\GitHub_Token.json"
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

            # Returned as-is: no expiry check / refresh (kept simple deliberately).
            return $data.access_token
        }
        catch {
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
            Uri     = 'https://github.com/login/device/code'
            Method  = 'Post'
            Body    = $body
            Headers = @{ Accept = 'application/json' }
        }
        return Invoke-RestMethod @req
    }

    # Polls GitHub's device-flow token endpoint once; Status tells the caller what next:
    # 'authorized' (token populated) / 'pending' / 'slow_down' (back off) / 'error' (stop).
    [PSCustomObject] PollForToken([string]$DeviceCode) {
        $body = @{
            client_id   = $this.ClientId
            device_code = $DeviceCode
            grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
        }
        try {
            $req = @{
                Uri     = 'https://github.com/login/oauth/access_token'
                Method  = 'Post'
                Body    = $body
                Headers = @{ Accept = 'application/json' }
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
        }
        catch {
            $this.Logger.LogDebug("Device-flow token poll failed (will retry): $($_.Exception.Message)")
            return [PSCustomObject]@{
                Status = 'pending'; AccessToken = $null; TokenData = $null; Error = $null
            }
        }
    }

    # --- Release management ---

    [PSCustomObject] GetLatestRelease([string]$Token) {
        $headers = @{
            Authorization = "token $Token"
            Accept        = "application/vnd.github.v3+json"
        }
        $uri = "https://api.github.com/repos/$($this.Owner)/$($this.Repo)/releases/latest"
        return Invoke-RestMethod -Uri $uri -Headers $headers
    }

    [PSCustomObject] GetReleaseAsset([PSCustomObject]$Release, [string]$Pattern) {
        foreach ($asset in $Release.assets) {
            if ($asset.name -like $Pattern) {
                return $asset
            }
        }
        return $null
    }

    [string] DownloadAsset([string]$Token, [PSCustomObject]$Asset, [string]$DestDir) {
        if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir | Out-Null }

        $destPath = Join-Path $DestDir $Asset.name
        $headers = @{
            Authorization = "token $Token"
            Accept        = "application/octet-stream"
        }

        Invoke-RestMethod -Uri $Asset.url -Headers $headers -OutFile $destPath
        return $destPath
    }

    [version] GetLocalVersion() {
        # Registry first (MSI installs); the match criteria mirror InstallWorker's.
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
        $verFile = Join-Path $env:LOCALAPPDATA "DONUT\version.txt"
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

        # Run the worker from the stage dir - the MSI replaces the source tree mid-install.
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

        Start-Process -FilePath "powershell.exe" -ArgumentList $argList -WindowStyle Hidden
    }
}
