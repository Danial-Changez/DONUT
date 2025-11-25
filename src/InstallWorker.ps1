
<#
    DONUT Install Worker
    Purpose:
        - Gracefully close running DONUT processes
        - Optionally uninstall previous version (rollback)
        - Install new MSI
        - Cleanup staging directory
#>
param(
    [Parameter(Mandatory = $true)][string]$MsiPath,
    [string]$StagePath,
    [string]$ProcessNameToClose = 'DONUT',
    [switch]$Passive,
    [switch]$Rollback,
    [int]$CloseTimeoutSeconds = 10
)

$ErrorActionPreference = 'Stop'

<#
    Get-DONUTUninstallInfo
    Purpose: Locate DONUT in Windows Uninstall registry.
    Returns: PSCustomObject with DisplayName, DisplayVersion, UninstallString, ProductCode, KeyPath; or $null.
#>
Function Get-DONUTUninstallInfo {
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
                $location = if ($app.PSObject.Properties.Name -contains 'InstallLocation') { [string]$app.InstallLocation } else { $null }
                return [PSCustomObject]@{
                    DisplayName     = $app.DisplayName
                    DisplayVersion  = if ($app.PSObject.Properties.Name -contains 'DisplayVersion') { [string]$app.DisplayVersion } else { $null }
                    InstallLocation = $location
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

<#
    Invoke-MsiInstall
    Purpose: Install MSI package with optional passive UI and logging.
    Returns: Exit code from msiexec.
#>
Function Invoke-MsiInstall {
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

<#
    Invoke-MsiUninstallViaMsi
    Purpose: Uninstall MSI package by path, with optional passive UI.
    Returns: Exit code from msiexec.
#>
Function Invoke-MsiUninstall {
    param(
        [Parameter(Mandatory = $true)][string]$ProdCode,
        [switch]$Passive
    )
    $ui = if ($Passive) { '/passive' } else { '/qb!' }
    $msiArguments = "/x `"$ProdCode`" $ui REBOOT=ReallySuppress"
    $p = Start-Process -FilePath 'msiexec' -ArgumentList $msiArguments -Wait -PassThru
    return [int]$p.ExitCode
}

<#
    Stop-DonutProcessGracefully
    Purpose: Attempt to close running DONUT processes gracefully, then force-kill if needed.
#>
Function Stop-DonutProcessGracefully {
    param([string]$Name, [int]$TimeoutSeconds = 10)
    $procs = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    
    if (-not $procs) { return }
    foreach ($p in $procs) { try { $null = $p.CloseMainWindow() } catch {} }
    
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 200
        $alive = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
        if (-not $alive) { break }
    }
    $still = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    
    if ($still) { foreach ($p in $still) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {} } }
}

# -------------------- Main install logic --------------------
try {
    # Gracefully close running app instances
    if ($ProcessNameToClose) { Stop-DonutProcessGracefully -Name $ProcessNameToClose -TimeoutSeconds $CloseTimeoutSeconds }
    $info = Get-DONUTUninstallInfo
    $exePath = Join-Path -Path $info.InstallLocation -ChildPath 'bin\x64\DONUT\DONUT.exe'
    
    # Optional uninstall first (rollback)
    if ($Rollback) {
        $unExit = Invoke-MsiUninstall -ProdCode $info.ProductCode -Passive:$Passive
        if (@(0, 3010, 1605) -notcontains $unExit) {
            Write-Error "Uninstall failed with exit code $unExit"
            exit 1
        }
    }

    # Install new MSI
    $logPath = Join-Path -Path ([IO.Path]::GetDirectoryName($MsiPath)) -ChildPath 'msi-install.log'
    $exit = Invoke-MsiInstall -MsiPath $MsiPath -LogPath $logPath -Passive:$Passive
    if (@(0, 3010) -notcontains $exit) {
        Write-Error "MSI install failed with exit code $exit. See log: $logPath"
        exit 1
    }

    # Cleanup staging if requested
    if ($StagePath -and (Test-Path -LiteralPath $StagePath)) {
        try { Remove-Item -LiteralPath $StagePath -Recurse -Force -ErrorAction Stop } catch { Write-Host "[WARN] Failed to remove stage: $($_.Exception.Message)" -ForegroundColor Yellow }
    }

    if (Test-Path $exePath) {
        try { Start-Process -FilePath $exePath } catch { Write-Host "[WARN] Failed to launch DONUT: $($_.Exception.Message)" -ForegroundColor Yellow }
    }
    exit 0
}
catch {
    Write-Host ("[ERROR] " + $_.Exception.Message) -ForegroundColor Red
    exit 1
}