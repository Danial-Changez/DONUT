<#
.SYNOPSIS
    Minimal remote-device state DTO: hostname, IP, online flag, status message.

.DESCRIPTION
    Carries a target's identity and reachability through a worker run; passed to
    ExecutionService's per-phase methods (scan / apply / inventory / disk).
#>
class DeviceContext {
    [string] $HostName
    [string] $IPAddress
    [bool] $IsOnline
    [string] $StatusMessage

    DeviceContext([string]$hostName) {
        $this.HostName = $hostName
        $this.IsOnline = $false
        $this.StatusMessage = "Initialized"
    }
}
