param(
    [string]$ComputerName
)

# Import the functions module
Import-Module (Join-Path -Path $PSScriptRoot -ChildPath "Read-Config.psm1")

# Read configuration from config file
$configPath = Join-Path -Path $PSScriptRoot -ChildPath "..\config.txt";
$config = Read-Config -configPath $configPath;
$logs = $false
$reports = $false

# Determine local log file name based on the outputLog parameter
if ($config.Args.ContainsKey("outputLog") -and $config.Args["outputLog"]) {
    $outputLogPath = $config.Args["outputLog"];
    $logFileName = Split-Path $outputLogPath -Leaf;
    $localLogFile = Join-Path -Path $PSScriptRoot -ChildPath "..\logs\$logFileName";
    $logs = $true
} else {
    $outputLogPath = $null
    $localLogFile = Join-Path -Path $PSScriptRoot -ChildPath "..\logs\default.log"
}

# Determine local report file name based on the report parameter
if ($config.Args.ContainsKey("report") -and $config.Args["report"]) {
    $reportPath = $config.Args["report"];
    $reportFileName = Split-Path $reportPath -Leaf;
    $localReportFile = Join-Path -Path $PSScriptRoot -ChildPath "..\reports\$reportFileName";
    $reports = $true
} else {
    $reportPath = $null
}

# Create log file if it does not exist
if (-not (Test-Path $localLogFile) -and $logs) {
    New-Item -Path $localLogFile -ItemType File -Force | Out-Null
}

# File path for host list, ensuring it exists
$hostFile = Join-Path -Path $PSScriptRoot -ChildPath "..\res\WSID.txt";
if (-not (Test-Path $hostFile)) {
    New-Item -Path $hostFile -ItemType File -Force | Out-Null
}

# Determine host list (Always single for UI)
if ($ComputerName) {
    $hostNames = @($ComputerName)
}
else {
    $hostNames = Get-Content -Path $hostFile | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
}

# Script block to process each computer (just one in this case for UI)
$processComputer = {
    $computer = $_
    $parsedIP = $null

    # See if an IP address was provided
    if ([System.Net.IPAddress]::TryParse($computer, [ref]$parsedIP)) {
        $ip = $parsedIP
    }

    else {
        # Try to resolve a single IP
        try {
            $ip = [System.Net.Dns]::GetHostAddresses("$computer")[0]
        }
        catch {
            Write-Warning "[$computer] DNS lookup failed: $_"
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
            # 1722 is RPC SERVER UNAVAILABLE
            if ($_.Exception.ErrorCode -eq 1722) {
                Write-Warning "[$computer] RPC Server unavailable, skipping..."
                Add-Content -Path $using:localLogFile -Value "[$computer] RPC server unavailable"
                return
            }
            else { 
                Write-Warning "[$computer] SocketException during reverse-DNS: $_"
                Add-Content -Path $using:localLogFile -Value "[$computer] SocketException: $_"
                return
            }
        }
        catch {
            Write-Warning "[$computer] Unexpected error during reverse-DNS: $_"
            Add-Content -Path $using:localLogFile -Value "[$computer] Reverse-DNS error: $_"
            return
        }
    }

    # Build UNC paths for remote log files
    $remoteLogUNC = $null
    if ($using:logs -and $using:outputLogPath) {
        $logRelPath = $using:outputLogPath -replace ":", "$"
        $remoteLogUNC = "\\$ip\$logRelPath"
    }

    Write-Host " `nProcessing computer: $computer...`n "

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
        Write-Warning "[$computer] $($_.Exception.Message), skipping..."
        Add-Content -Path $($using:localLogFile) -Value "[$computer] $_"
        return
    }
    
    Write-Host "Found dcu-cli.exe on $computer at: `"$dcuPath`"" -ForegroundColor Green

    # Build and execute DCU update command
    $stopDCU = "Stop-Process -Name `"DellCommandUpdate`" -Force -ErrorAction SilentlyContinue; "
    $enabledCmd = [string]$using:config.EnabledCmdOption
    $arguments = [string]$using:config.Arguments
    $remoteCommand = "$stopDCU & `"$dcuPath`" /$enabledCmd $arguments"

    # PsExec command to execute the remote command
    $psexec = "psexec -accepteula -nobanner -s -h -i \\$ip pwsh -c '$remoteCommand'"

    Write-Host "Executing '$enabledCmd' on $computer..."
    Write-Host "`nCommand: $psexec"
    try {
        Invoke-Expression $psexec
    }
    catch {
        Write-Warning "[$computer] Failed to run DCU command: $_"
        Add-Content -Path $($using:localLogFile) -Value "[$computer] Command error: $_"
        return
    }

    Write-Host "Command executed on $computer. Waiting for remote log file generation (if it exists)..."
    Start-Sleep -Seconds 3

    # Build path for temporary per-computer log (in case multiple computers are processed)
    $tempLog = Join-Path -Path (Join-Path -Path $using:PSScriptRoot -ChildPath "..\logs") -ChildPath "$computer.log"
    $tempReport = Join-Path -Path (Join-Path -Path $using:PSScriptRoot -ChildPath "..\reports") -ChildPath "$computer.xml"
    if ($remoteLogUNC -and (Test-Path $remoteLogUNC -ErrorAction SilentlyContinue)) {
        try {
            $logContent = Get-Content -Path $remoteLogUNC -ErrorAction Stop
            Add-Content -Path $tempLog -Value "----- Log for $computer -----"
            Add-Content -Path $tempLog -Value $logContent
            Add-Content -Path $tempLog -Value ""
        }
        catch {
            Write-Warning "Failed to read remote log file from $computer : $_"
            Add-Content -Path $tempLog -Value "[$computer] Failed to retrieve remote log: $_"
        }
    }

    # Find XML file in remote report folder and copy to local as computer.xml
    if ($using:reports -and $using:reportPath) {
        $reportRelPath = $using:reportPath -replace ":", "$"
        $remoteReportFolder = "\\$ip\$reportRelPath"
        $tempReport = Join-Path -Path (Join-Path -Path $using:PSScriptRoot -ChildPath "..\reports") -ChildPath "$computer.xml"
        try {
            $xmlFiles = Get-ChildItem -Path $remoteReportFolder -Filter *.xml -ErrorAction Stop | Sort-Object LastWriteTime -Descending
            if ($xmlFiles.Count -gt 0) {
                $latestXmlFile = $xmlFiles[0].FullName
                $reportContent = Get-Content -Path $latestXmlFile -ErrorAction Stop
                Set-Content -Path $tempReport -Value $reportContent
                Write-Host "`nReport file for $computer copied to $tempReport`n"
            } else {
                Write-Warning "`n[$computer] No XML report file found in $remoteReportFolder`n"
                Set-Content -Path $tempReport -Value "[$computer] No XML report file found."
            }
        } catch {
            Write-Warning "`n[$computer] Could not find/copy XML report file in $($remoteReportFolder): $_`n"
            Set-Content -Path $tempReport -Value "[$computer] Failed to retrieve remote XML report: $_"
        }
    }
}

# Run the parallel loop using the ThrottleLimit from config
$hostNames | ForEach-Object -Parallel $processComputer -ThrottleLimit $config.ThrottleLimit
$logFolder = Join-Path -Path $PSScriptRoot -ChildPath "..\logs"

foreach ($computer in $hostNames) {
    $perHostLog = "$logFolder\$computer.log"
    if (Test-Path $perHostLog) {
        try {
            $logData = Get-Content -Path $perHostLog
            Add-Content -Path $localLogFile -Value $logData
            Remove-Item -Path $perHostLog -Force
        }
        catch {
            Write-Warning "[$computer] Error consolidating log file: $_"
            Add-Content -Path $localLogFile -Value "[$computer] Error consolidating log file: $_"
        }
    } else {
        Write-Warning "[$computer] No individual log found, skipping."
        Add-Content -Path $localLogFile -Value "[$computer] No log generated (skipped)."
    }
}