<#
.SYNOPSIS
    Installs the newest DONUT beta build into its own directory and switches the app
    to the beta channel.

.DESCRIPTION
    Reads the newest release from GitHub with prereleases included, verifies the MSI
    against its published SHA-256, installs it into InstallDir, locks that directory
    down to administrators, and seeds betaUpdates in the shared config so the first
    update check already follows the beta channel. Nothing here is beta-only
    machinery: the install is the same MSI stable ships, placed somewhere else.

.PARAMETER InstallDir
    Where DONUT installs. The package's own layout goes under it, so the exe lands
    at <InstallDir>\bin\x64\DONUT\DONUT.exe and later updates stay in place.

.PARAMETER Tag
    Pin one release (e.g. v2.4.57) instead of taking the newest.

.PARAMETER Token
    GitHub token, needed only when Owner/Repo is a private fork.

.NOTES
    Elevation is required: this is a per-machine install, and the ACL it applies is
    what makes an install outside Program Files safe. DONUT's app tree self-extracts
    beside the exe and runs elevated, so a directory any user can write to would let
    that user plant a DLL next to an elevated process. A folder created directly
    under C:\ by a standard user is exactly that, hence an explicit DACL rather than
    whatever the parent happened to inherit.

    One machine holds one DONUT: every build shares an UpgradeCode, so an install
    already sitting in Program Files is upgraded into InstallDir rather than joined
    by a second copy. Data lives in %ProgramData% and carries across untouched.

    Updating is the app's own job from here (Settings > Updates > Beta Channel).
    Rerunning this script is only for repairing an install or pinning an older tag.

.EXAMPLE
    pwsh -File tools\Install-Beta.ps1
    pwsh -File tools\Install-Beta.ps1 -InstallDir 'C:\Safe\Donut' -Tag v2.4.57
#>
#Requires -RunAsAdministrator
param(
    [string] $InstallDir = 'C:\Safe\Donut',
    [string] $Tag = '',
    [string] $Token = '',
    [string] $Owner = 'Danial-Changez',
    [string] $Repo = 'DONUT'
)

$ErrorActionPreference = 'Stop'

$headers = @{ Accept = 'application/vnd.github.v3+json' }
if ($Token) { $headers['Authorization'] = "token $Token" }
$api = "https://api.github.com/repos/$Owner/$Repo/releases"

# Downloads one release asset through its API url, which a private fork also answers.
function Save-Asset {
    param([Parameter(Mandatory = $true)][PSCustomObject] $Asset, [string] $Dir)

    $dest = Join-Path $Dir $Asset.name
    $assetHeaders = @{ Accept = 'application/octet-stream' }
    if ($Token) { $assetHeaders['Authorization'] = "token $Token" }
    Invoke-RestMethod -Uri $Asset.url `
                      -Headers $assetHeaders `
                      -OutFile $dest `
                      -TimeoutSec 300
    return $dest
}

# --- Release ---

$uri = if ($Tag) { "$api/tags/$Tag" } else { "${api}?per_page=10" }
$release = Invoke-RestMethod -Uri $uri -Headers $headers -TimeoutSec 15
# The list answers newest first, and a draft is not something anyone can install.
if (-not $Tag) {
    $release = $release | Where-Object { -not $_.draft } | Select-Object -First 1
}
if (-not $release) { throw "No release found in $Owner/$Repo." }

$msiAsset = $release.assets | Where-Object { $_.name -like '*.msi' } | Select-Object -First 1
$sumAsset = $release.assets | Where-Object { $_.name -like '*.sha256' } | Select-Object -First 1
if (-not $msiAsset) { throw "Release $($release.tag_name) publishes no MSI." }

$kind = if ($release.prerelease) { 'beta' } else { 'stable' }
Write-Host "Installing DONUT $($release.tag_name) ($kind) into $InstallDir..." -ForegroundColor Cyan

$stage = Join-Path $env:TEMP "donut-beta-$($release.tag_name)"
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$msi = Save-Asset -Asset $msiAsset -Dir $stage

if ($sumAsset) {
    $expected = ((Get-Content (Save-Asset -Asset $sumAsset -Dir $stage) -Raw) -split '\s+')[0].Trim()
    $actual = (Get-FileHash -Path $msi -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "SHA-256 mismatch on $($msiAsset.name). Install aborted." }
} else {
    Write-Warning 'This release publishes no checksum, so the MSI could not be verified.'
}

# --- Install ---

# Well-known SIDs, not names: BUILTIN\Users does not exist under that name everywhere.
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$acl = [System.Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true, $false)
$acl.SetOwner([System.Security.Principal.SecurityIdentifier]'S-1-5-32-544')
foreach ($grant in @(@('S-1-5-18', 'FullControl'), @('S-1-5-32-544', 'FullControl'),
        @('S-1-5-32-545', 'ReadAndExecute'))) {
    $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            [System.Security.Principal.SecurityIdentifier]$grant[0],
            $grant[1],
            'ContainerInherit, ObjectInherit',
            'None',
            'Allow'))
}
Set-Acl -Path $InstallDir -AclObject $acl

$log = Join-Path $stage 'msi-install.log'
$msiArgs = "/i `"$msi`" INSTALLFOLDER=`"$($InstallDir.TrimEnd('\'))`" " +
"REBOOT=ReallySuppress /passive /log `"$log`""
$proc = Start-Process -FilePath 'msiexec' `
                      -ArgumentList $msiArgs `
                      -Wait `
                      -PassThru
if (@(0, 3010) -notcontains $proc.ExitCode) {
    throw "msiexec failed with exit code $($proc.ExitCode). See $log."
}

# --- Channel ---

# Seeded before first launch, so the very first check already looks at prereleases.
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
Write-Host "Installed. Start it from $InstallDir\bin\x64\DONUT\DONUT.exe" -ForegroundColor Green
