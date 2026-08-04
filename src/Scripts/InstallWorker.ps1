<#
.SYNOPSIS
    Standalone updater that installs (or rolls back) the DONUT MSI.

.DESCRIPTION
    Launched out-of-process by SelfUpdateService once an MSI is downloaded and
    SHA-256 verified. Gracefully closes any running DONUT process, optionally
    uninstalls the current version (rollback), installs the MSI via msiexec, then
    cleans up the staging directory and relaunches the app.

.PARAMETER MsiPath
    Path to the downloaded, verified MSI to install.

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
#>
param(
    [string]$MsiPath,
    [string]$ProcessNameToClose = 'DONUT',
    [switch]$Passive,
    [switch]$Rollback,
    [int]$CloseTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

# Finds the installed DONUT entry in the Uninstall registry (DisplayName + Publisher
# match); returns its product code / install location / version, or $null if absent.
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
        }
        catch {}   # unreadable key -> treat as not installed
    }
    return $null
}

# Installs the MSI with reboot suppressed; returns msiexec's exit code
# (1603 when the MSI path is missing).
function Invoke-MsiInstall {
    param(
        [Parameter(Mandatory = $true)][string]$MsiPath,
        [string]$LogPath,
        [switch]$Passive
    )

    if (-not (Test-Path $MsiPath)) {
        Write-Error "MSI not found: $MsiPath"
        return 1603
    }

    $ui = if ($Passive) { '/passive' } else { '/qb!' }
    $logArg = if ($LogPath) { "/log `"$LogPath`"" } else { '' }
    $msiArguments = "/i `"$MsiPath`" REBOOT=ReallySuppress $ui $logArg"
    $p = Start-Process -FilePath 'msiexec' -ArgumentList $msiArguments -Wait -PassThru

    return [int]$p.ExitCode
}

# Uninstalls the given product code with reboot suppressed; returns msiexec's exit code.
function Invoke-MsiUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$ProdCode,
        [switch]$Passive
    )

    $ui = if ($Passive) { '/passive' } else { '/qb!' }
    $msiArguments = "/x `"$ProdCode`" $ui REBOOT=ReallySuppress"
    $p = Start-Process -FilePath 'msiexec' -ArgumentList $msiArguments -Wait -PassThru

    return [int]$p.ExitCode
}

# Closes running DONUT windows, waits up to TimeoutSeconds, then force-kills any survivors.
function Stop-DonutProcessGracefully {
    param([string]$Name, [int]$TimeoutSeconds = 10)
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)

    if (-not $procs) { return }
    foreach ($p in $procs) {
        try {
            $null = $p.CloseMainWindow()
        }
        catch {}
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
            }
            catch {}
        }
    }
}

# Surfaces a fatal update error to the user: this worker runs in a hidden window, so its
# console output is invisible. Best-effort; never throws.
function Show-UpdateError {
    param([string]$Message)
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show(
            $Message, 'DONUT Update',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
    catch {}
}

# --- Main install logic ---
try {
    if ($ProcessNameToClose) {
        Stop-DonutProcessGracefully -Name $ProcessNameToClose -TimeoutSeconds $CloseTimeoutSeconds
    }
    # $info is $null on a box with no registered install (first install, portable
    # run) - Join-Path's mandatory -Path would throw under EAP=Stop and abort the
    # whole update, so the relaunch path stays optional.
    $info = Get-DONUTUninstallInfo
    $exePath = if ($info -and $info.InstallLocation) {
        Join-Path -Path $info.InstallLocation -ChildPath 'bin\x64\DONUT\DONUT.exe'
    }
    else { $null }

    # A rollback uninstalls the newer build first so the older MSI installs clean.
    # With nothing registered there is nothing to uninstall; fall through to the
    # plain install of the older MSI.
    if ($Rollback -and $info) {
        $unExit = Invoke-MsiUninstall -ProdCode $info.ProductCode -Passive:$Passive
        if (@(0, 3010, 1605) -notcontains $unExit) {
            Show-UpdateError "DONUT rollback failed (code $unExit). It may need a manual reinstall."
            Write-Error "Uninstall failed with exit code $unExit"
            exit 1
        }
    }

    $logPath = Join-Path -Path ([IO.Path]::GetDirectoryName($MsiPath)) -ChildPath 'msi-install.log'
    $exit = Invoke-MsiInstall -MsiPath $MsiPath -LogPath $logPath -Passive:$Passive

    if (@(0, 3010) -notcontains $exit) {
        Show-UpdateError "DONUT update failed (code $exit).`nSee log: $logPath"
        Write-Error "MSI install failed with exit code $exit. See log: $logPath"
        exit 1
    }

    # The checksum stages next to the MSI (UpdatePresenter downloads both);
    # remove the pair or the .sha256 outlives every update forever.
    foreach ($staged in @($MsiPath, "$MsiPath.sha256")) {
        if ($staged -and (Test-Path -LiteralPath $staged)) {
            try {
                Remove-Item -LiteralPath $staged -Force -ErrorAction Stop
            }
            catch {
                Write-Host "[WARN] Failed to remove $staged`: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if ($exePath -and (Test-Path $exePath)) {
        try {
            Start-Process -FilePath $exePath
        }
        catch {
            Show-UpdateError "DONUT updated but couldn't relaunch. Open it from the Start Menu."
            Write-Host "[WARN] Failed to launch DONUT: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    exit 0
}
catch {
    Show-UpdateError "DONUT update failed:`n$($_.Exception.Message)"
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}
