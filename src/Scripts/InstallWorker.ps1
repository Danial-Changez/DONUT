<#
.SYNOPSIS
    Standalone updater that installs (or rolls back) a DONUT MSI or zip.

.DESCRIPTION
    Launched out-of-process by SelfUpdateService once a package is downloaded and
    SHA-256 verified. Gracefully closes any running DONUT process, then either
    installs the MSI via msiexec (optionally uninstalling first for a rollback) or
    unpacks the zip over an existing directory, cleans up the staging directory and
    relaunches the app.

.PARAMETER MsiPath
    Path to the downloaded, verified MSI to install.

.PARAMETER ZipPath
    Path to the downloaded, verified zip, for an install that msiexec does not own.
    Mutually exclusive with MsiPath, and needs InstallDir.

.PARAMETER InstallDir
    Directory a zip install owns, which is where it unpacks and relaunches from.

.PARAMETER ProcessNameToClose
    Process to stop before installing (default 'DONUT').

.PARAMETER Passive
    Run msiexec with a passive (non-interactive) UI.

.PARAMETER Rollback
    Uninstall the current version first (revert to an older tag).

.PARAMETER CloseTimeoutSeconds
    Seconds to wait for a graceful process close before forcing it.

.NOTES
    Kept as a standalone script (not a class) so it can be copied to the data
    root and run independently of the install it is replacing.

    The install passes the registered InstallLocation back as INSTALLFOLDER. A
    major upgrade otherwise resolves the default Program Files path, which would
    silently migrate a beta install out of its own directory (tools/Install-Beta.ps1).
#>
param(
    [string]$MsiPath,
    [string]$ZipPath,
    [string]$InstallDir,
    [string]$ProcessNameToClose = 'DONUT',
    [switch]$Passive,
    [switch]$Rollback,
    [int]$CloseTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

# Finds the installed DONUT entry in the Uninstall registry by DisplayName and
# Publisher. Returns its product code, install location, and version, or $null.
function Get-DONUTUninstallInfo {
    $path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
    if (-not (Test-Path $path)) { return $null }

    $subKeys = Get-ChildItem -Path $path -ErrorAction SilentlyContinue
    foreach ($subKey in $subKeys) {
        try {
            $app = Get-ItemProperty -Path $subKey.PSPath -ErrorAction SilentlyContinue
            if (-not $app) { continue }
            if ($app.DisplayName -like '*DONUT*' -and $app.Publisher -like '*Bakery*') {
                $props = $app.PSObject.Properties.Name
                $uninst = if ($props -contains 'UninstallString') { [string]$app.UninstallString }
                else { $null }
                $prodCode = if ($props -contains 'ProductCode' -and $app.ProductCode) { [string]$app.ProductCode }
                else { $subKey.PSChildName }
                $location = if ($props -contains 'InstallLocation') { [string]$app.InstallLocation }
                else { $null }
                $dispVer = if ($props -contains 'DisplayVersion') { [string]$app.DisplayVersion }
                else { $null }
                return [PSCustomObject]@{
                    DisplayName     = $app.DisplayName
                    DisplayVersion  = $dispVer
                    InstallLocation = $location
                    UninstallString = $uninst
                    ProductCode     = $prodCode
                    KeyPath         = $subKey.PSPath
                }
            }
        } catch {}   # An unreadable key reads as not installed.
    }
    return $null
}

# Installs the MSI with reboot suppressed. Returns msiexec's exit code, or 1603 when
# the MSI path is missing. InstallFolder keeps a non-default install where it is.
function Invoke-MsiInstall {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [string]$LogPath,
        [string]$InstallFolder,
        [switch]$Passive
    )

    if (-not (Test-Path $MsiPath)) {
        Write-Error "MSI not found: $MsiPath"
        return 1603
    }

    $ui = if ($Passive) { '/passive' } else { '/qb!' }
    $logArg = if ($LogPath) { "/log `"$LogPath`"" } else { '' }
    # Trailing backslash trimmed: it would escape the closing quote on msiexec's command line.
    $folderArg = if ($InstallFolder) {
        "INSTALLFOLDER=`"$($InstallFolder.TrimEnd('\'))`""
    } else { '' }
    $msiArguments = "/i `"$MsiPath`" REBOOT=ReallySuppress $folderArg $ui $logArg"
    $p = Start-Process -FilePath 'msiexec' `
                       -ArgumentList $msiArguments `
                       -Wait `
                       -PassThru

    return [int]$p.ExitCode
}

# Uninstalls the given product code with reboot suppressed, returning msiexec's code.
function Invoke-MsiUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$ProdCode,
        [switch]$Passive
    )

    $ui = if ($Passive) { '/passive' } else { '/qb!' }
    $msiArguments = "/x `"$ProdCode`" $ui REBOOT=ReallySuppress"
    $p = Start-Process -FilePath 'msiexec' `
                       -ArgumentList $msiArguments `
                       -Wait `
                       -PassThru

    return [int]$p.ExitCode
}

# Unpacks the zip over an install directory. Copy-over, not replace: the app tree the
# launcher extracts beside the exe is not in the zip and must survive the update.
function Install-DonutZip {
    param(
        [Parameter(Mandatory = $true)][string]$ZipPath,
        [Parameter(Mandatory = $true)][string]$InstallDir
    )

    if (-not (Test-Path $ZipPath)) { throw "Zip not found: $ZipPath" }
    $unpack = Join-Path ([IO.Path]::GetDirectoryName($ZipPath)) 'unpack'
    if (Test-Path $unpack) { Remove-Item $unpack -Recurse -Force }

    Expand-Archive -LiteralPath $ZipPath -DestinationPath $unpack -Force
    if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
    Copy-Item -Path (Join-Path $unpack '*') `
              -Destination $InstallDir `
              -Recurse `
              -Force
    Remove-Item $unpack -Recurse -Force -ErrorAction SilentlyContinue
}

# Closes running DONUT windows, waits up to TimeoutSeconds, then force-kills any survivors.
function Stop-DonutProcessGracefully {
    param([string]$Name, [int]$TimeoutSeconds = 10)
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)

    if (-not $procs) { return }
    foreach ($p in $procs) {
        try {
            $null = $p.CloseMainWindow()
        } catch {}
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $alive = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        if (-not $alive) { break }
    }
    $still = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)

    if ($still) {
        foreach ($p in $still) {
            try {
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }
}

# Surfaces a fatal update error: this worker runs in a hidden window, so its console
# output is invisible. Best effort, and never throws.
function Show-UpdateError {
    param([string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $Message, 'DONUT Update',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
}

# --- Main install logic ---
try {
    if ($ProcessNameToClose) {
        Stop-DonutProcessGracefully -Name $ProcessNameToClose -TimeoutSeconds $CloseTimeoutSeconds
    }
    $package = if ($ZipPath) { $ZipPath } else { $MsiPath }
    $exePath = $null

    if ($ZipPath) {
        # A rollback is just an older zip: nothing to uninstall, the files are replaced.
        Install-DonutZip -ZipPath $ZipPath -InstallDir $InstallDir
        $exePath = Join-Path -Path $InstallDir -ChildPath 'DONUT.exe'
    } else {
        # Join-Path's mandatory -Path would throw under EAP=Stop when nothing is registered.
        $info = Get-DONUTUninstallInfo
        $exePath = if ($info -and $info.InstallLocation) {
            Join-Path -Path $info.InstallLocation -ChildPath 'bin\x64\DONUT\DONUT.exe'
        } else { $null }

        # A rollback uninstalls the newer build first so the older MSI installs clean.
        if ($Rollback -and $info) {
            $unExit = Invoke-MsiUninstall -ProdCode $info.ProductCode -Passive:$Passive
            if (@(0, 3010, 1605) -notcontains $unExit) {
                Show-UpdateError "DONUT rollback failed (code $unExit). It may need a manual reinstall."
                Write-Error "Uninstall failed with exit code $unExit"
                exit 1
            }
        }

        $logPath = Join-Path -Path ([IO.Path]::GetDirectoryName($MsiPath)) -ChildPath 'msi-install.log'
        # The recorded location, or a beta install outside Program Files would migrate back into it.
        $folder = if ($info) { [string]$info.InstallLocation } else { '' }
        $exit = Invoke-MsiInstall -MsiPath $MsiPath `
                                  -LogPath $logPath `
                                  -InstallFolder $folder `
                                  -Passive:$Passive

        if (@(0, 3010) -notcontains $exit) {
            Show-UpdateError "DONUT update failed (code $exit).`nSee log: $logPath"
            Write-Error "MSI install failed with exit code $exit. See log: $logPath"
            exit 1
        }
    }

    # Remove the pair, or the staged .sha256 outlives every update forever.
    foreach ($staged in @($package, "$package.sha256")) {
        if ($staged -and (Test-Path -LiteralPath $staged)) {
            try {
                Remove-Item -LiteralPath $staged -Force -ErrorAction Stop
            } catch {
                Write-Host "[WARN] Failed to remove $staged`: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if ($exePath -and (Test-Path $exePath)) {
        try {
            Start-Process -FilePath $exePath
        } catch {
            Show-UpdateError "DONUT updated but couldn't relaunch. Open it from the Start Menu."
            Write-Host "[WARN] Failed to launch DONUT: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    exit 0
} catch {
    Show-UpdateError "DONUT update failed:`n$($_.Exception.Message)"
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
