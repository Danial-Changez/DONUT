param(
    [string]$ComputerName
)

# Import the functions module
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Read-Config.psm1")

# Read configuration from config file
$configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\config.txt";
$config = Read-Config -configPath $configPath;

# Determine local log file name based on the outputLog parameter
if ($config.Args.ContainsKey("outputLog") -and $config.Args["outputLog"]) {
    $outputLogPath = $config.Args["outputLog"];
    $logFileName   = Split-Path $outputLogPath -Leaf;
    $localLogFile  = Join-Path -Path $PSScriptRoot -ChildPath "..\logs\$logFileName";
}
else {
    $localLogFile  = Join-Path -Path $PSScriptRoot -ChildPath "..\logs\default.log"
}

# Create log file if it does not exist
if (-not (Test-Path $localLogFile)) {
    New-Item -Path $localLogFile -ItemType File -Force | Out-Null;
}

# Determine host list
if ($ComputerName) {
    # single-host mode
    $hostNames = @($ComputerName)
}
else {
    # File path for host list
    $hostFile = Join-Path -Path $PSScriptRoot -ChildPath "..\res\WSID.txt";

    # Ensure host file exists
    if (-not (Test-Path $hostFile)) {
        Write-Error "WSID file not found at $hostFile." -ForegroundColor Red
        exit 1
    }

    # Read host names (ignoring empty lines)
    $hostNames = Get-Content -Path $hostFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

Write-Host "Starting processing for $($hostNames.Count) computers using '$($config.EnabledCmdOption)' command."

# Script block to process each computer
$processComputer = {
    $computer = $_
    $parsedIP = $null
    if ([System.Net.IPAddress]::TryParse($computer, [ref]$parsedIP)) {
        $ip = $parsedIP
    }

    else {
        # Try to resolve a single IP
        try {
            $ip = [System.Net.Dns]::GetHostAddresses("$computer")[0]
        }
        catch {
            Write-Error "[$computer] DNS lookup failed: $_"
            Add-Content -Path $using:localLogFile -Value "[$computer] DNS lookup failed: $_"
            return
        }
    
        # Reverse-DNS lookup + name check
        try {
            $hostEntry = [System.Net.Dns]::GetHostEntry($ip)
            $resolvedName = $hostEntry.HostName.Split('.')[0]
        
            if ($resolvedName -ne $computer) {
                Write-Warning "[$computer] Reverse-DNS returned '$resolvedName' (expected '$computer'), skipping..."
                Add-Content -Path $using:localLogFile -Value "[$computer] Incorrect reverse-DNS: $resolvedName"
                return
            }
        }
        catch [System.Net.Sockets.SocketException] {
            # 1722 is RPC_S_SERVER_UNAVAILABLE
            if ($_.Exception.ErrorCode -eq 1722) {
                Write-Warning "[$computer] RPC Server unavailable, skipping..."
                Add-Content -Path $using:localLogFile -Value "[$computer] RPC server unavailable"
                return
            }
            else { 
                Write-Error "[$computer] SocketException during reverse-DNS: $_"
                Add-Content -Path $using:localLogFile -Value "[$computer] SocketException: $_"
                return
            }
        }
        catch {
            Write-Error "[$computer] Unexpected error during reverse-DNS: $_"
            Add-Content -Path $using:localLogFile -Value "[$computer] Reverse-DNS error: $_"
            return
        }
    }

    Write-Host "--------------------------------"
    Write-Host " Processing computer: $computer "
    Write-Host "--------------------------------"

    
    # Checks for dcu-cli.exe (32-bit or 64-bit)
    try {
        if (Test-Path "\\$ip\C$\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe") {
            $dcuPath = "C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe"
        }
        elseif (Test-Path "\\$ip\C$\Program Files\Dell\CommandUpdate\dcu-cli.exe") {
            $dcuPath = "C:\Program Files\Dell\CommandUpdate\dcu-cli.exe"
        }
        else {
            throw "dcu-cli.exe not found"
        }
    }
    catch {
        Write-Error "[$computer] $($_.Exception.Message), skipping..."
        Add-Content -Path $($using:localLogFile) -Value "[$computer] $_"
        return
    }
    
    Write-Host "Found dcu-cli.exe on $computer at: $dcuPath" -ForegroundColor Green
    
    # Build and execute DCU update command
    $stopDCU = "Stop-Process -Name `"DellCommandUpdate`" -Force -ErrorAction SilentlyContinue; "
    $enabledCmd = [string]$using:config.EnabledCmdOption
    $arguments  = [string]$using:config.Arguments
    $remoteCommand = "$stopDCU & `"$dcuPath`" /$enabledCmd $arguments"

    # PsExec command to execute the remote command
    $psexec = "psexec -accepteula -nobanner -s -h -i \\$ip pwsh -c '$remoteCommand'"

    Write-Host "Executing '$enabledCmd' on $computer..."
    try {
        Invoke-Expression $psexec
    }
    catch {
        Write-Error "[$computer] Failed to run DCU command: $_"
        Add-Content -Path $($using:localLogFile) -Value "[$computer] Command error: $_"
        return
    }

    Write-Host "Command executed on $computer. Waiting for remote log file generation..."
    Start-Sleep -Seconds 1

    # Retrieve remote log file using parenthesized config access for outputLog
    if ((($using:config).Args).ContainsKey("outputLog") -and ((($using:config).Args)["outputLog"])) {
        $remoteLogName = Split-Path ((($using:config).Args)["outputLog"]) -Leaf
    }
    else {
        $remoteLogName = "default.log"
    }

    $remoteLogUNC = "\\$ip\c$\temp\dcuLogs\$remoteLogName"
    # Build path for temporary per-computer log
    $tempLog = Join-Path -Path (Join-Path -Path $using:PSScriptRoot -ChildPath "..\logs") -ChildPath "$computer.log"

    if (Test-Path $remoteLogUNC) {
        try {
            $logContent = Get-Content -Path $remoteLogUNC -ErrorAction Stop
            Add-Content -Path $tempLog -Value "----- Log for $computer -----"
            Add-Content -Path $tempLog -Value $logContent
            Add-Content -Path $tempLog -Value ""
            Write-Host "Log file for $computer appended to $tempLog"
        }
        catch {
            Write-Error "Failed to read remote log file from $computer : $_"
            Add-Content -Path $tempLog -Value "[$computer] Failed to retrieve remote log: $_"
        }
    }
    else {
        Write-Error "Remote log file was not found for $computer."
        Add-Content -Path $tempLog -Value "[$computer] Remote log file not found."
    }
    Write-Host ""
}

# Run the parallel loop using the ThrottleLimit from config
$hostNames | ForEach-Object -Parallel $processComputer -ThrottleLimit $config.ThrottleLimit
Add-Content -Path $localLogFile -Value ""

$logFolder = Join-Path -Path $PSScriptRoot -ChildPath "..\logs"

foreach ($computer in $hostNames) {
    $perHostLog = "$logFolder\$computer.log"

    if (-not (Test-Path $perHostLog)) {
        Write-Warning "[$computer] No individual log found, skipping."
        Add-Content -Path $localLogFile -Value "[$computer] No log generated (skipped)."
        return
    }

    try {
        $logData = Get-Content -Path $perHostLog
        Add-Content -Path $localLogFile -Value $logData
        Remove-Item -Path $perHostLog -Force
    }
    catch {
        Write-Warning "[$computer] Error consolidating log file: $_"
        Add-Content -Path $localLogFile -Value "[$computer] Error consolidating log file: $_"
    }
}

Write-Host "Processing completed for all computers. Please review the log file at $localLogFile for details." -ForegroundColor Green