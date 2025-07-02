function Read-Config {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$configPath
    )

    if (-not (Test-Path $configPath)) {
        throw "Config file not found: $configPath";
    }

    # Read all nonempty, trimmed lines from the config file
    $configLines = Get-Content -Path $configPath | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # Hash table to store each section's configuration
    $commands = @{};
    $throttleLimit = $null;
    $currentCommand = $null;
    
    foreach ($line in $configLines) {
        # Check if the line defines the throttle limit
        if ($line -match '^throttleLimit\s*=\s*(\d+)$') {
            $throttleLimit = [int]$Matches[1];
            continue;
        }

        # Lines not starting with "-" define a command option (section header) with the format: commandOption = status
        if ($line -notmatch "^-") {
            $parts = $line -split "=", 2;
            if ($parts.Count -eq 2) {
                $commandName = $parts[0].Trim();
                $status = $parts[1].Trim();
                $commands[$commandName] = [PSCustomObject]@{
                    Status = $status;
                    Args   = @{};
                }
                $currentCommand = $commandName;
            }
        }
        else {
            # Lines starting with "-" are arguments for the current command option.
            if ($currentCommand) {
                $lineContent = $line.TrimStart("-").Trim();
                $argParts = $lineContent -split "=", 2;
                if ($argParts.Count -eq 2) {
                    $argKey = $argParts[0].Trim();
                    $argValue = $argParts[1].Trim().Trim('"');
                    $commands[$currentCommand].Args[$argKey] = $argValue;
                }
            }
        }
    }
    
    # Ensure exactly one section is enabled (e.g., scan = enable)
    $enabledOptions = $commands.GetEnumerator() | Where-Object { $_.Value.Status -eq "enable" };
    if ($enabledOptions.Count -ne 1) {
        throw "Exactly one option must be enabled. Found $($enabledOptions.Count) enabled options."
    }
    $enabledOption = $enabledOptions | Select-Object -First 1;

    # Build a concatenated arguments string from the enabled section's Args
    $argString = ($enabledOption.Value.Args.GetEnumerator() | ForEach-Object {
            if ($_.Value) {
                if ($_.Key -eq "silent") {
                    "-$($_.Key)"
                }
                else {
                    "-$($_.Key)=`"$($_.Value)`"" 
                }
            }
        } | Where-Object { $_ }) -join " "
    
    return [PSCustomObject]@{
        EnabledCmdOption = [string]$enabledOption.Key;
        Arguments        = $argString;
        ThrottleLimit    = $throttleLimit;
        Args             = $enabledOption.Value.Args
    }
}