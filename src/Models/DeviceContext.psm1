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
