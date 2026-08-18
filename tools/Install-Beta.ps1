<#
.SYNOPSIS
    Installs the newest DONUT beta build into its own directory and switches the app
    to the beta channel.

.DESCRIPTION
    Reads the newest release from GitHub with prereleases included, verifies the zip
    against its published SHA-256, unpacks it into InstallDir, writes that directory's
    permissions, and seeds betaUpdates in the shared config so the first update check
    already follows the beta channel.

    The zip rather than the MSI, deliberately: msiexec owns one install per machine,
    so installing the beta as an MSI would move an existing stable install instead of
    standing beside it. A zip install registers nothing, updates itself from the same
    zip asset, and can be removed by deleting its directory.

.PARAMETER InstallDir
    Where DONUT unpacks. The zip is flat, so the exe lands at <InstallDir>\DONUT.exe
    and every later update replaces it in place.

.PARAMETER Tag
    Pin one release (e.g. v2.4.57) instead of taking the newest.

.PARAMETER Token
    GitHub token, needed only when Owner/Repo is a private fork.

.NOTES
    Run it as the admin account DONUT itself elevates to. That account owns the folder
    and is the only one able to write it, which is what makes an install outside
    Program Files safe: DONUT's app tree self-extracts beside the exe and runs
    elevated, so a directory any user can write to would let that user plant a DLL
    next to an elevated process, and a folder created under C:\ by a standard user is
    exactly that. The desktop's own user is granted read and execute so a de-elevated
    launch still works, and updates write as the admin account this install elevates
    to. Nobody else is named, inheritance is dropped rather than trusted, and no
    well-known SID is written: an account that can bypass a DACL was never limited by
    one being there.

    Nothing is registered with Windows Installer, so this install stands beside an
    MSI one instead of replacing it, and uninstalling is deleting the directory. Both
    share %ProgramData%\DONUT\data, including the beta toggle this seeds.

    Updating is the app's own job from here (Settings > Updates > Beta Channel), and
    it replaces this directory's files from the same zip. Rerunning this script is
    only for repairing an install or pinning an older tag.

.EXAMPLE
    pwsh -File tools\Install-Beta.ps1
    pwsh -File tools\Install-Beta.ps1 -InstallDir "$env:windir\Temp\Donut" -Tag v2.4.57
#>
#Requires -RunAsAdministrator
param(
    [string] $InstallDir = "$env:windir\Temp\Donut",
    [string] $Tag = '',
    [string] $Token = '',
    [string] $Owner = 'Danial-Changez',
    [string] $Repo = 'DONUT'
)

$ErrorActionPreference = 'Stop'

$headers = @{ Accept = 'application/vnd.github.v3+json' }
if ($Token) { $headers['Authorization'] = "token $Token" }
$api = "https://api.github.com/repos/$Owner/$Repo/releases"

# Logged-on user
function Get-InteractiveUser {
    try {
        $session = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($filter in @("Name='explorer.exe' AND SessionId=$session", "Name='explorer.exe'")) {
            $explorer = Get-CimInstance Win32_Process -Filter $filter -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $explorer) { continue }

            $owner = Invoke-CimMethod -InputObject $explorer `
                                      -MethodName GetOwner `
                                      -ErrorAction SilentlyContinue
            if ($owner -and $owner.User) {
                return "$($owner.Domain)\$($owner.User)"
            }
        }
        return $null
    } catch {
        return $null
    }
}

# Downloads a release asset through its API url
function Save-Asset {
    param(
        [Parameter(Mandatory = $true)][PSCustomObject] $Asset,
        [string] $Dir
    )

    $dest = Join-Path $Dir $Asset.name
    $assetHeaders = @{ Accept = 'application/octet-stream' }

    if ($Token) {
        $assetHeaders['Authorization'] = "token $Token"
    }

    Invoke-RestMethod -Uri $Asset.url `
                      -Headers $assetHeaders `
                      -OutFile $dest `
                      -TimeoutSec 300
    return $dest
}

# Release

$uri = if ($Tag) { "$api/tags/$Tag" } else { "${api}?per_page=10" }
$release = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15

if (-not $Tag) {
    $release = $release | Where-Object { -not $_.draft } | Select-Object -First 1
}
if (-not $release) {
    throw "No release found in $Owner/$Repo."
}

$zipAsset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $zipAsset) {
    throw "Release $($release.tag_name) publishes no zip, so it predates this install path."
}
$sumAsset = $release.assets |
    Where-Object { $_.name -eq "$($zipAsset.name).sha256" } | Select-Object -First 1

$kind = if ($release.prerelease) { 'beta' } else { 'stable' }
Write-Host "Installing DONUT $($release.tag_name) ($kind) into $InstallDir..." -ForegroundColor Cyan

$stage = Join-Path $env:TEMP "donut-beta-$($release.tag_name)"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$zip = Save-Asset -Asset $zipAsset -Dir $stage

if ($sumAsset) {
    $expected = ((Get-Content (Save-Asset -Asset $sumAsset -Dir $stage) -Raw) -split '\s+')[0].Trim()
    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash

    if ($actual -ne $expected) {
        throw "SHA-256 mismatch on $($zipAsset.name). Install aborted."
    }
} else {
    Write-Warning 'This release publishes no checksum, so the zip could not be verified.'
}

# Install

$admin = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

$acl = [System.Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner($admin)
$acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $admin,
        'FullControl',
        'ContainerInherit, ObjectInherit',
        'None',
        'Allow'))

$desktopUser = Get-InteractiveUser
$desktopSid = $null
if ($desktopUser) {
    try {
        $desktopSid = ([System.Security.Principal.NTAccount]$desktopUser).Translate(
            [System.Security.Principal.SecurityIdentifier])
    } catch {
        Write-Warning "$desktopUser did not resolve, so it was left out of the folder's rights."
    }
} else {
    Write-Warning 'No interactive session found, so only the installing account may use this folder.'
}

if ($desktopSid -and $desktopSid.Value -ne $admin.Value) {
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $desktopSid,
            'ReadAndExecute',
            'ContainerInherit, ObjectInherit',
            'None',
            'Allow'))
}
Set-Acl -Path $InstallDir -AclObject $acl

Expand-Archive -LiteralPath $zip -DestinationPath $InstallDir -Force
$exe = Join-Path $InstallDir 'DONUT.exe'
if (-not (Test-Path $exe)) {
    throw "The zip unpacked without a DONUT.exe in $InstallDir."
}

# Elevated here, and the desktop launch will not be: the app tree is admin-only by design.
Start-Process -FilePath $exe -ArgumentList '--extract-only' -Wait
if (-not (Test-Path (Join-Path $InstallDir 'app\src\Start-Donut.ps1'))) {
    Write-Warning 'The app tree was not staged, so start DONUT as an administrator once.'
}

$lnk = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\DONUT (beta).lnk'
$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
$shortcut.TargetPath = $exe
$shortcut.WorkingDirectory = $InstallDir
$shortcut.Save()

# Channel

$configPath = Join-Path $env:ProgramData 'DONUT\data\config\config.json'
$settings = if (Test-Path $configPath) {
    Get-Content $configPath -Raw | ConvertFrom-Json
} else {
    [PSCustomObject]@{}
}

$settings | Add-Member -NotePropertyName 'betaUpdates' `
                       -NotePropertyValue $true `
                       -Force
New-Item -ItemType Directory `
         -Path (Split-Path $configPath -Parent) `
         -Force | Out-Null

$settings | ConvertTo-Json -Depth 10 | Set-Content -Path $configPath

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Installed. Start it from $exe, or the DONUT (beta) shortcut." -ForegroundColor Green
