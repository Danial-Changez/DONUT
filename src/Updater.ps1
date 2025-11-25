<#
    DONUT Updater
    Purpose:
        - Discover installed DONUT version (if any)
        - Acquire/refresh GitHub App user token via Device Flow (UI)
        - Fetch latest GitHub release and MSI asset, verify SHA256, and hand off install to worker
        - Show an Update popup when local != remote (supports rollback when remote < local)

    Notes:
        - Token expiry times are handled as UTC (stored in ISO 8601). Refresh uses refresh_token grant.
        - Local token bundle is DPAPI-protected (CurrentUser) and ACL’d to the interactive user.
        - MSI downloads are performed via the GitHub assets API (octet-stream) and guarded against HTML/SSO.
        - The install worker script is copied to %LOCALAPPDATA%\DONUT and launched with pwsh in the background.
#>
param(
    # GitHub configuration (private org repo)
    [string]$GitOwner = 'Cooperators-EIOS',
    [string]$GitRepo = 'DONUT',
    # App Client ID (Device Flow for GitHub App user token)
    [string]$GitClientId = 'Iv23liCYT0SXs7j31VnT',
    # For testing: force showing the Device Flow UI even if a token exists
    [switch]$ForceDeviceFlow,
    # (Optional) Name/pattern of the release MSI asset (if naming convention is changed in the future)
    [string]$MsiAssetPattern = '*.msi',
    # When set, emit a boolean status (update launched) to the pipeline for callers like Startup.pss
    [switch]$EmitStatus
)

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Security
Add-Type -AssemblyName System.Windows.Forms

Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'ImportXaml.psm1')
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath 'Helpers.psm1')

$ErrorActionPreference = 'Stop'
$script:Queue = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()

# -------------------- Helpers: Version, Token storage, HTTP --------------------
<#
    Compare-Version
    Inputs: v1, v2 (strings, may be prefixed with v/V)
    Output: -1 if v1 < v2, 0 if equal, 1 if v1 > v2
    Behavior: falls back to ordering if parse fails on either side.
#>
Function Compare-Version($v1, $v2) {
    try { [version]$ver1 = ($v1 -replace '^[vV]', '') } catch { return -1 }
    try { [version]$ver2 = ($v2 -replace '^[vV]', '') } catch { return 1 }
    return $ver1.CompareTo($ver2)
}

<#
    Get-DONUTUninstallInfo
    Purpose: Locate DONUT in Windows Uninstall registry.
    Returns: PSCustomObject with DisplayName, DisplayVersion, UninstallString, ProductCode, KeyPath; or $null.
#>
Function Get-DONUTUninstallInfo {
    # Return uninstall metadata for DONUT from Uninstall registry
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not (Test-Path $path)) { return $null }
    $subKeys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
    foreach ($subKey in $subKeys) {
        try {
            $app = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
            if (-not $app) { continue }
            if ($app.DisplayName -like '*DONUT*' -and $app.Publisher -like '*Bakery*') {
                $uninst = if ($app.PSObject.Properties.Name -contains 'UninstallString') { [string]$app.UninstallString } else { $null }
                $prodCode = if ($app.PSObject.Properties.Name -contains 'ProductCode' -and $app.ProductCode) { [string]$app.ProductCode } else { $subKey.PSChildName }
                return [PSCustomObject]@{
                    DisplayName     = $app.DisplayName
                    DisplayVersion  = if ($app.PSObject.Properties.Name -contains 'DisplayVersion') { [string]$app.DisplayVersion } else { $null }
                    UninstallString = $uninst
                    ProductCode     = $prodCode
                    KeyPath         = $subKey.PSPath
                }
            }
        }
        catch {}
    }
    return $null
}

# Local token storage (DPAPI-protected)
$TokenDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DONUT'
$TokenJson = Join-Path -Path $TokenDir -ChildPath 'GitHub_Token.json'  # encrypted JSON bundle

<#
    Set-PrivateFileAcl
    Purpose: Restrict file ACLs to the current user and hide the file.
    Inputs: Path (string)
#>
Function Set-PrivateFileAcl([string]$Path) {
    try {
        $user = New-Object System.Security.Principal.NTAccount($env:USERDOMAIN, $env:USERNAME)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $user,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow
        )
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $acl.SetAccessRuleProtection($true, $false)
        [void]$acl.SetAccessRule($rule)
        [System.IO.File]::SetAccessControl($Path, $acl)
        try { [System.IO.File]::SetAttributes($Path, ([System.IO.File]::GetAttributes($Path) -bor [System.IO.FileAttributes]::Hidden)) } catch {}
    }
    catch {}
}

# -------------------- Device Flow token storage --------------------
<#
    Save-GitHubTokens
    Purpose: Persist access/refresh tokens with UTC expiry timestamps, DPAPI-protected.
    Inputs: AccessToken (mandatory), AccessTokenExpiresIn (sec), RefreshToken, RefreshTokenExpiresIn (sec)
#>
Function Save-GitHubTokens {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [int]$AccessTokenExpiresIn,
        [string]$RefreshToken,
        [int]$RefreshTokenExpiresIn
    )
    if (-not (Test-Path $TokenDir)) { New-Item -ItemType Directory -Path $TokenDir | Out-Null }
    $now = [DateTime]::UtcNow
    $obj = [ordered]@{
        access_token       = $AccessToken
        expires_at         = if ($AccessTokenExpiresIn) { $now.AddSeconds($AccessTokenExpiresIn).ToString('o') } else { $null }
        refresh_token      = $RefreshToken
        refresh_expires_at = if ($RefreshTokenExpiresIn) { $now.AddSeconds($RefreshTokenExpiresIn).ToString('o') } else { $null }
        token_type         = 'bearer'
        version            = 2
    }
    $json = ($obj | ConvertTo-Json -Compress)
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
    [IO.File]::WriteAllBytes($TokenJson, $protected)
    Set-PrivateFileAcl -Path $TokenJson
}

<#
    Get-GitHubTokenBundle
    Purpose: Read, decrypt, and parse the stored token JSON bundle.
    Returns: PSObject with access/refresh token fields and UTC expiry, or $null.
#>
Function Get-GitHubTokenBundle {
    if (Test-Path $TokenJson) {
        try {
            $protected = [IO.File]::ReadAllBytes($TokenJson)
            $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
            $jsonText = [Text.Encoding]::UTF8.GetString($bytes)
            $obj = $jsonText | ConvertFrom-Json
            return $obj
        }
        catch {}
    }
    return $null
}

<#
    Get-GitHubTokenStored
    Purpose: Convenience accessor for the access_token string from the stored bundle.
#>
Function Get-GitHubTokenStored { 
    $b = Get-GitHubTokenBundle
    if ($b) { return [string]$b.access_token } 
    else { return $null }
}

<#
    Update-GitHubToken
    Purpose: Use refresh_token grant to obtain a new access_token. Updates persisted bundle.
    Returns: New access_token string, or $null if refresh not possible/expired.
#>
Function Update-GitHubToken {
    $bundle = Get-GitHubTokenBundle
    
    if (-not $bundle -or -not $bundle.refresh_token) { return $null }
    $now = [DateTime]::UtcNow
    
    if ($bundle.refresh_expires_at) {
        $rExpiry = [DateTime]::Parse($bundle.refresh_expires_at, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        if ($rExpiry -le $now) { return $null }
    }
    $resp = Invoke-GitHubApi -Uri 'https://github.com/login/oauth/access_token' -Method 'POST' -Headers @{ Accept = 'application/json' } -Body @{
        client_id     = $GitClientId
        grant_type    = 'refresh_token'
        refresh_token = $bundle.refresh_token
    } -ContentType 'application/x-www-form-urlencoded'
    
    if ($resp.access_token) {
        $atExp = if ($resp.PSObject.Properties.Name -contains 'expires_in') { [int]$resp.expires_in } else { 0 }
        $rt = if ($resp.PSObject.Properties.Name -contains 'refresh_token') { [string]$resp.refresh_token } else { $bundle.refresh_token }
        $rtExp = if ($resp.PSObject.Properties.Name -contains 'refresh_token_expires_in') { [int]$resp.refresh_token_expires_in } else { 0 }
        Save-GitHubTokens -AccessToken $resp.access_token -AccessTokenExpiresIn $atExp -RefreshToken $rt -RefreshTokenExpiresIn $rtExp
        return $resp.access_token
    }
    return $null
}

<#
    Get-GitHubAccessTokenSafe
    Purpose: Return a valid access_token, refreshing if near expiry; optionally force login UI.
    Inputs: -ForceLogin switch (opens Device Flow UI if no valid token).
#>
Function Get-GitHubAccessTokenSafe {
    param([switch]$ForceLogin)
    $bundle = Get-GitHubTokenBundle
    $now = [DateTime]::UtcNow
    
    if ($bundle -and $bundle.access_token) {
        if (-not $bundle.expires_at) { return [string]$bundle.access_token }
        $leeway = [TimeSpan]::FromMinutes(2)
        $aExpiry = [DateTime]::Parse($bundle.expires_at, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)

        if ($aExpiry - $leeway -gt $now) { return [string]$bundle.access_token }
        $newTok = Update-GitHubToken
        if ($newTok) { return $newTok }
    }
    
    if ($ForceLogin) { [void](Show-GitHubLoginWindow); return (Get-GitHubTokenStored) }
    return $null
}

# -------------------- Backup user data before updates --------------------
<#
    Backup-UserData
    Purpose: Copy logs folder, reports folder, and config.txt to %LOCALAPPDATA%\DONUT\UserData
    Notes: Non-throwing; best-effort copy.
#>
Function Backup-UserData {
    try {
        $projRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
        $userData = Join-Path $env:LOCALAPPDATA 'DONUT\UserData'
        if (-not (Test-Path $userData)) { New-Item -ItemType Directory -Path $userData -Force | Out-Null }

        foreach ($name in 'logs','reports') {
            $src = Join-Path $projRoot $name
            $dst = Join-Path $userData $name
            if (Test-Path $src) {
                try { Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force -ErrorAction Stop } catch {}
            }
        }

        $cfgSrc = Join-Path $projRoot 'config.txt'
        if (Test-Path $cfgSrc) {
            $cfgDst = Join-Path $userData 'config.txt'
            try { Copy-Item -LiteralPath $cfgSrc -Destination $cfgDst -Force -ErrorAction Stop } catch {}
        }
    }
    catch {}
}

# HTTP helpers
$script:GitHeadersBase = @{ 
    Accept                 = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent'           = 'DONUT-Updater-GHA'
}
<#
    Invoke-GitHubApi
    Purpose: Typed wrapper over Invoke-RestMethod with common params.
#>
Function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        [object]$Body = $null,
        [string]$ContentType
    )
    $params = @{ Uri = $Uri; Method = $Method; Headers = $Headers; ErrorAction = 'Stop' }
    if ($Body) { $params.Body = $Body }
    if ($ContentType) { $params.ContentType = $ContentType }
    return Invoke-RestMethod @params
}

# -------------------- WPF Login with RunspacePool --------------------
<#
    Show-GitHubLoginWindow
    Purpose: UI for GitHub Device Flow.
    Flow:
      1) Phase 1: Request device/user code, open verification URL, display code, copy to clipboard.
      2) Phase 2: Poll access_token in background via runspace pool.
      3) On success: Save tokens (with UTC expiry) and close window.
    Returns: $true if a token exists when the window closes; otherwise $false.
#>
Function Show-GitHubLoginWindow {
    # If we already have a valid (or refreshable) token and not forcing, skip UI
    if (-not $ForceDeviceFlow -and (Get-GitHubAccessTokenSafe)) { return $true }

    $window = Import-Xaml '..\Views\Login.xaml'
    if (-not $window) { return $false }

    # Merge style/resource dictionaries
    Add-ResourceDictionaries -window $window

    # Set background image
    $bg = $window.FindName('Background')
    $bgPath = Join-Path $PSScriptRoot '..\Images\background.jpeg'
    $bg.ImageSource = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$bgPath)

    # Control bar
    ($window.FindName('panelControlBar')).Add_MouseLeftButtonDown({ $window.DragMove() }) | Out-Null
    ($window.FindName('btnMinimize')).Add_Click({ $window.WindowState = 'Minimized' }) | Out-Null
    ($window.FindName('btnClose')).Add_Click({ $window.Close() }) | Out-Null

    $btnGit = $window.FindName('btnGitHubAuth')
    $outBox = $window.FindName('Output')
    $accessLink = $window.FindName('AccessLink')
    if ($accessLink) {
        try {
            $accessLink.Add_RequestNavigate({
                    param($s, $e)
                    try { Start-Process $e.Uri.AbsoluteUri } catch {}
                    try { $e.Handled = $true } catch {}
                }) | Out-Null
        }
        catch {}
    }

    # Set login button image
    $imgPath = Join-Path $PSScriptRoot '..\Images\GitHub.png'
    if (Test-Path $imgPath) {
        $bmp = [System.Windows.Media.Imaging.BitmapImage]::new([Uri]$imgPath)
        $btnGit.Background = [System.Windows.Media.ImageBrush]::new($bmp)
    }

    # Append helper (must be called on UI thread only)
    $uiAppend = {
        param([string]$m)
        if (-not $outBox) { return }
        try {
            $outBox.AppendText([string]$m)
            
            if (-not $m.EndsWith("`r`n")) { $outBox.AppendText("`r`n") }
            $outBox.ScrollToEnd()
        }
        catch {}
    }

    if (-not $script:Timer) {
        $script:Timer = [System.Windows.Threading.DispatcherTimer]::new([System.Windows.Threading.DispatcherPriority]::Normal, $window.Dispatcher)
        $script:Timer.Interval = [TimeSpan]::FromMilliseconds(100)
        $script:Timer.Add_Tick({
                param($s, $e)
                try {
                    while ($true) {
                        $msg = $null
                        if (-not $script:Queue.TryDequeue([ref]$msg)) { break }

                        if ($msg -like 'Error:*') {
                            & $uiAppend ("Error: " + $msg.Substring(6))
                            try { if ($btnGit) { $btnGit.IsEnabled = $true } } catch {}
                        }
                        elseif ($msg -like 'Device:*') {
                            $payload = $msg.Substring(7)
                            $parts = $payload -split '\|'
                            $userCode = $parts[0]
                            $verifyUri = $parts[1]
                            $interval = [int]$parts[2]
                            $expiresIn = [int]$parts[3]
                            $deviceCode = $parts[4]
                            $copied = $false
                            try { Set-Clipboard -Value $userCode -ErrorAction Stop; $copied = $true } catch { $copied = $false }
                            if ($copied) {
                                & $uiAppend 'Code copied to clipboard.'
                            }
                            else {
                                & $uiAppend "Couldn't copy to clipboard automatically, copy the code below manually."
                            }
                            & $uiAppend ("Enter this code: " + $userCode)
                            & $uiAppend ("Then open: " + $verifyUri)

                            # Start polling (Phase 2) in background
                            $pollScript = {
                                param($deviceCode, $clientId, $interval, $expires, [System.Collections.Concurrent.ConcurrentQueue[string]] $q)
                                $pollUri = 'https://github.com/login/oauth/access_token'
                                $deadline = (Get-Date).AddSeconds([int]$expires)
                                $headers = @{ Accept = 'application/json' }
                                while ((Get-Date) -lt $deadline) {
                                    Start-Sleep -Seconds $interval
                                    try {
                                        $resp = Invoke-RestMethod -Uri $pollUri -Method 'POST' -Headers $headers -Body @{
                                            client_id   = $clientId
                                            device_code = $deviceCode
                                            grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                                        } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                                        if ($resp.access_token) { $q.Enqueue("Json Token:" + ($resp | ConvertTo-Json -Compress)); return }
                                        if ($resp.error) {
                                            if ($resp.error -eq 'authorization_pending') { $q.Enqueue("Pending Authorization..."); continue }
                                            elseif ($resp.error -eq 'slow_down') { $interval = [Math]::Min($interval + 5, 30); $q.Enqueue("Slow Down:" + $interval); continue }
                                            elseif ($resp.error -eq 'expired_token') { $q.Enqueue('Token Expired'); return }
                                            elseif ($resp.error -eq 'access_denied') { $q.Enqueue('Access Denied'); return }
                                            else { $q.Enqueue("Error:" + $resp.error) }
                                        }
                                    }
                                    catch { $q.Enqueue("Exception:" + $_.Exception.Message) }
                                }
                                $q.Enqueue('Timeout')
                            }
                            $script:PsPoll = [PowerShell]::Create()
                            $script:PsPoll.RunspacePool = $script:Pool
                            $null = $script:PsPoll.AddScript([string]$pollScript).AddArgument($deviceCode).AddArgument($GitClientId).AddArgument($interval).AddArgument($expiresIn).AddArgument($script:Queue)
                            $null = $script:PsPoll.BeginInvoke()
                        }
                        elseif ($msg -like 'Json Token:*') {
                            $json = $msg.Substring(11)
                            try {
                                $o = $json | ConvertFrom-Json
                                $atExp = if ($o.PSObject.Properties.Name -contains 'expires_in') { [int]$o.expires_in } else { 0 }
                                $rt = if ($o.PSObject.Properties.Name -contains 'refresh_token') { [string]$o.refresh_token } else { $null }
                                $rtExp = if ($o.PSObject.Properties.Name -contains 'refresh_token_expires_in') { [int]$o.refresh_token_expires_in } else { 0 }
                                if ($rt) { Save-GitHubTokens -AccessToken $o.access_token -AccessTokenExpiresIn $atExp -RefreshToken $rt -RefreshTokenExpiresIn $rtExp }
                                else { Save-GitHubTokens -AccessToken $o.access_token }
                            }
                            catch { }
                            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
                            try { if ($script:PsDev) { $script:PsDev.Dispose() } } catch {}
                            try { if ($script:PsPoll) { $script:PsPoll.Dispose() } } catch {}
                            try { if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose() } } catch {}
                            try { if ($window) { $window.Close() } } catch {}
                            return
                        }
                        else {
                            & $uiAppend $msg
                        }
                    }
                }
                catch {}
            })
        $script:Timer.Start()
    }

    if ($btnGit) {
        $btnGit.Add_Click({
                try {
                    $btnGit.IsEnabled = $false
                    & $uiAppend "Starting GitHub Device Flow..."
                    if (-not $GitClientId) { throw 'GitClientId is missing.' }

                    # Ensure runspace pool exists
                    if (-not $script:Pool) {
                        $script:Pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(1, 2)
                        $script:Pool.ApartmentState = 'MTA'
                        $script:Pool.Open()
                    }

                    # Device-flow phase 1
                    $deviceScript = {
                        param($clientId, [System.Collections.Concurrent.ConcurrentQueue[string]] $q)
                        try {
                            $resp = Invoke-RestMethod -Uri 'https://github.com/login/device/code' -Method 'POST' -Headers @{ Accept = 'application/json' } -Body @{ client_id = $clientId; scope = 'repo' } -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
                            $uri = if ($resp.PSObject.Properties.Name -contains 'verification_uri_complete' -and $resp.verification_uri_complete) { $resp.verification_uri_complete } else { $resp.verification_uri }
                            try { Start-Process $uri } catch {}
                            $q.Enqueue("Device:" + $resp.user_code + '|' + $uri + '|' + [int]$resp.interval + '|' + [int]$resp.expires_in + '|' + $resp.device_code)
                        }
                        catch { $q.Enqueue("[ERROR] " + $_.Exception.Message) }
                    }

                    $script:PsDev = [PowerShell]::Create()
                    $script:PsDev.RunspacePool = $script:Pool
                    $null = $script:PsDev.AddScript([string]$deviceScript).AddArgument($GitClientId).AddArgument($script:Queue)
                    $null = $script:PsDev.BeginInvoke()
                }
                catch {
                    & $uiAppend ("[ERROR] " + $_.Exception.Message)
                    try { $btnGit.IsEnabled = $true } catch {}
                }
            })
    }

    # Cleanup when window closes
    $window.Add_Closed({ 
            try { if ($script:Timer) { $script:Timer.Stop() } } catch {}
            try { if ($script:PsDev) { $script:PsDev.Dispose() } } catch {}
            try { if ($script:PsPoll) { $script:PsPoll.Dispose() } } catch {}
            try { if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose() } } catch {}
            $script:Timer = $null; 
            $script:Pool = $null; 
            $script:PsDev = $null; 
            $script:PsPoll = $null 
        })

    $null = $window.ShowDialog()
    return [bool](Get-GitHubAccessTokenSafe)
}

# -------------------- Release discovery and download --------------------
Function Get-LatestRelease {
    param([string]$Token)
    $headers = $script:GitHeadersBase.Clone()
    $headers.Authorization = "Bearer $Token"
    try {
        $url = "https://api.github.com/repos/$GitOwner/$GitRepo/releases/latest"
        $rel = Invoke-GitHubApi -Uri $url -Headers $headers
        return $rel
    }
    catch {
        $msg = $_.Exception.Message
        Write-Host "[ERROR] Failed to fetch latest release. Ensure your token is authorized for $GitOwner. Details: $msg" -ForegroundColor Red
        return $null
    }
}

Function Get-ReleaseAsset {
    param(
        $Release,
        [string]$Pattern
    )
    $asset = $Release.assets | Where-Object { $_.name -like $Pattern } | Select-Object -First 1
    if (-not $asset) { $asset = $Release.assets | Where-Object { $_.name -like '*.msi' } | Select-Object -First 1 }
    return $asset
}

Function Get-ReleaseAssetFile {
    param(
        [string]$Token,
        [object]$Asset,
        [string]$OutFile
    )

    # Use the assets API with octet-stream to get a pre-authorized redirect to the binary
    $headers = @{ 
        Authorization = "Bearer $Token"; 
        'User-Agent'  = 'DONUT-Updater-GHA';
        Accept        = 'application/octet-stream'
    }
    $apiUrl = "https://api.github.com/repos/$GitOwner/$GitRepo/releases/assets/$($Asset.id)"
    Invoke-WebRequest -Uri $apiUrl -Headers $headers -OutFile $OutFile -UseBasicParsing -ErrorAction Stop | Out-Null
    
    # Guard against HTML/SSO responses being saved as .msi
    try {
        $fs = [IO.File]::Open($OutFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $len = [Math]::Min(256, [int]$fs.Length)
            $buf = New-Object byte[] $len
            $null = $fs.Read($buf, 0, $len)
            $head = [Text.Encoding]::ASCII.GetString($buf, 0, $len)
            if ($head -match '<!DOCTYPE|<html' -or $head -match 'Sign in.*GitHub') {
                Write-Error "Downloaded HTML instead of binary (authorization/SSO issue)."
                return
            }
        }
        finally { $fs.Dispose() }
    }
    catch {
        try { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue } catch {}
        Write-Host "[ERROR] Failed to verify downloaded asset file: $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}

Function Confirm-ReleaseAssetHash {
    param(
        [object]$Asset,
        [string]$FilePath
    )
    
    # Prefer the SHA256 digest published on the asset JSON
    $expected = $null
    if ($Asset -and ($Asset.PSObject.Properties.Name -contains 'digest')) {
        $expected = [string]$Asset.digest
    }
    elseif ($Asset -and ($Asset.PSObject.Properties.Name -contains 'digests')) {
        $d = $Asset.digests
        if ($d -is [string]) { $expected = [string]$d }
        elseif ($d -and ($d.PSObject.Properties.Name -contains 'sha256')) { $expected = [string]$d.sha256 }
        else {
            # Take first string-like value
            foreach ($p in $d.PSObject.Properties) { if ($p.Value -is [string] -and $p.Value) { $expected = [string]$p.Value; break } }
        }
    }
    if (-not $expected) { Write-Error '[ERROR] No digest present on asset JSON to verify MSI.'; return $false }

    # Normalize common formats: "sha256:ABC...", "ABC...  filename", etc.
    $expected = $expected.Trim()
    
    if ($expected -match 'sha256:') { $expected = ($expected -split 'sha256:')[1] }
    $expected = ($expected -split '\s+')[0]
    $expected = $expected.Trim().ToUpperInvariant()
    $localHash = (Get-FileHash -Path $FilePath -Algorithm SHA256).Hash.Trim().ToUpperInvariant()
    
    if ($localHash -ne $expected) { Write-Error "[ERROR] SHA256 mismatch for $([IO.Path]::GetFileName($FilePath))"; return $false }
    return $true
}

# -------------------- Update orchestration --------------------

# Signal to caller (Startup.pss) whether an update was launched this run
$script:UpdateLaunched = $false

# Discover local install metadata and version
$installInfo = Get-DONUTUninstallInfo
${localVersion} = if ($installInfo -and $installInfo.DisplayVersion) { [string]$installInfo.DisplayVersion } else { '0.0.0' }

# Ensure token is available via Login UI (force when testing). Reuses stored token to avoid re-opening UI.
$token = $null
if ($ForceDeviceFlow) {
    $loginResult = Show-GitHubLoginWindow -Force:$true
    if ($loginResult) { $token = Get-GitHubAccessTokenSafe }
    if (-not $token) {
        Write-Host "Forced authentication was not completed. Exiting updater." -ForegroundColor Red
        exit
    }
}
elseif (-not (Get-GitHubTokenStored)) {
    $loginResult = Show-GitHubLoginWindow
    if ($loginResult) { $token = Get-GitHubAccessTokenSafe }
    if (-not $token) {
        Write-Host "Authentication was not completed. Exiting updater." -ForegroundColor Red
        exit
    }
}
else {
    # Try to use/refresh existing token silently; fall back to login if needed
    $token = Get-GitHubAccessTokenSafe
    if (-not $token) {
        $loginResult = Show-GitHubLoginWindow
        if ($loginResult) { $token = Get-GitHubAccessTokenSafe }
    }
}

# Window initialization for the Update popup UI
$window = Import-Xaml '..\Views\Update.xaml'
Add-ResourceDictionaries -window $window

# Ensure worker is copied before any update logic (copy only if missing or changed by SHA256)
$workerSrc = Join-Path -Path $PSScriptRoot -ChildPath 'InstallWorker.ps1'
$workerDir = Join-Path -Path $env:LOCALAPPDATA -ChildPath 'DONUT'

if (-not (Test-Path $workerDir)) { New-Item -ItemType Directory -Path $workerDir | Out-Null }
$workerDst = Join-Path -Path $workerDir -ChildPath 'InstallWorker.ps1'

if (-not (Test-Path $workerDst) -or ((Get-FileHash -Path $workerSrc -Algorithm SHA256).Hash -ne (Get-FileHash -Path $workerDst -Algorithm SHA256).Hash)) {
    Copy-Item -LiteralPath $workerSrc -Destination $workerDst -Force
}

# Fetch latest release info from GitHub
$remoteVersion = $null
$release = $null
try {
    $release = Get-LatestRelease -Token $token
    $remoteVersion = $release.tag_name
}
catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    $remoteVersion = $localVersion
}

# If not installed, perform auto-install of latest MSI without prompting (leaving for future use)
if (-not $installInfo) {
    try {
    # Backup user data before auto-install of latest
    Backup-UserData
        if (-not $token) {
            $null = Show-GitHubLoginWindow -Force:$true
            $token = Get-GitHubAccessTokenSafe -ForceLogin
            if (-not $token) { Write-Error "No token available." }
        }
        # Prepare asset
        if (-not $release) { $release = Get-LatestRelease -Token $token }
        $asset = Get-ReleaseAsset -Release $release -Pattern $MsiAssetPattern
        
        if (-not $asset) { Write-Error 'No matching MSI asset found in latest release.' }
        $stage = Join-Path -Path $env:TEMP -ChildPath "DONUT"
        
        if (-not (Test-Path $stage)) { New-Item -ItemType Directory -Path $stage | Out-Null }
        $filePath = Join-Path -Path $stage -ChildPath "$($asset.name)_$($release.tag_name)"

        Get-ReleaseAssetFile -Token $token -Asset $asset -OutFile $filePath
        Confirm-ReleaseAssetHash -Asset $asset -FilePath $filePath | Out-Null

        $Arguments = @('-ExecutionPolicy', 'Bypass', '-File', "`"$workerDst`"", '-MsiPath', "`"$filePath`"", '-StagePath', "`"$stage`"", '-ProcessNameToClose', 'DONUT')
        Start-Process -FilePath 'pwsh' -ArgumentList $Arguments -WindowStyle Hidden | Out-Null
        Write-Host 'Installer launched in background. This app may close.' -ForegroundColor Green
        
        # Flag that an update was launched so caller can skip MainWindow
        $script:UpdateLaunched = $true
        if ($EmitStatus) { return $script:UpdateLaunched } else { return }
    }
    catch {
        Write-Host "[ERROR] Auto-install handoff failed: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }
}

# PopUp logic (show when versions differ: update or rollback)
if (Compare-Version $localVersion $remoteVersion -ne 0) {
    $btnNow = $window.FindName('btnNow')
    $btnLater = $window.FindName('btnLater')
    $btnClose = $window.FindName('btnClose')
    $btnMinimize = $window.FindName('btnMinimize')
    $panelControlBar = $window.FindName('panelControlBar')

    $btnNow.Add_Click({
            try {
                $null = Show-GitHubLoginWindow -Force:$true
                $token = Get-GitHubAccessTokenSafe -ForceLogin

                $asset = Get-ReleaseAsset -Release $release -Pattern $MsiAssetPattern
                if (-not $asset) { Write-Error 'No matching MSI asset found in latest release.' }

                $stage = Join-Path -Path $env:TEMP -ChildPath "DONUT"
                if (-not (Test-Path $stage)) { New-Item -ItemType Directory -Path $stage | Out-Null }

                $filePath = Join-Path -Path $stage -ChildPath "$($asset.name)_$($remoteVersion)"
                Get-ReleaseAssetFile -Token $token -Asset $asset -OutFile $filePath
                Confirm-ReleaseAssetHash -Asset $asset -FilePath $filePath | Out-Null

                if ($asset.name -like '*.msi') {
                    # Backup user data before handing off to worker
                    Backup-UserData
                    $isRollback = (Compare-Version $localVersion $remoteVersion -gt 0)
                    $Arguments = @('-ExecutionPolicy', 'Bypass', '-File', "`"$workerDst`"", '-MsiPath', "`"$filePath`"", '-StagePath', "`"$stage`"", '-ProcessNameToClose', 'DONUT')
                    if ($isRollback) { $Arguments += '-Rollback' }
                    Start-Process -FilePath 'pwsh' -ArgumentList $Arguments -WindowStyle Hidden | Out-Null
                    Write-Host 'Installer launched in background. This app may close.' -ForegroundColor Green
                    # Flag that an update was launched so caller can skip MainWindow
                    $script:UpdateLaunched = $true
                }
            }
            catch {
                Write-Host "Update Failed: $($_.Exception.Message)" -ForegroundColor Red
                exit
            }
            $window.Close()
        })
    $btnLater.Add_Click({ $window.Close() })

    if ($btnClose) { $btnClose.Add_Click({ try { $window.Close() } catch {} }) }
    if ($btnMinimize) { $btnMinimize.Add_Click({ try { $window.WindowState = 'Minimized' } catch {} }) }
    if ($panelControlBar) { $panelControlBar.Add_MouseLeftButtonDown({ try { $window.DragMove() } catch {} }) }

    $null = $window.ShowDialog()
    if ($EmitStatus) { return $script:UpdateLaunched } else { return }
}

# If no version difference and no early return occurred
if ($EmitStatus) { return $script:UpdateLaunched }