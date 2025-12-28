using namespace System.Net
using namespace System.Net.Sockets

class NetworkProbe {
    
    [IPAddress] ResolveHost([string]$hostName) {
        try {
            $addresses = [Dns]::GetHostAddresses($hostName)
            if ($addresses.Count -gt 0) {
                return $addresses[0]
            }
        }
        catch {
            # DNS resolution failed
        }
        return $null
    }

    [bool] CheckReverseDNS([IPAddress]$ip, [string]$expectedHostName) {
        try {
            $entry = [Dns]::GetHostEntry($ip)
            return $entry.HostName -like "*$expectedHostName*"
        }
        catch {
            return $false
        }
    }

    [bool] IsRpcAvailable([string]$hostName) {
        # Test TCP port 135 (RPC Endpoint Mapper)
        try {
            $client = [TcpClient]::new()
            $result = $client.BeginConnect($hostName, 135, $null, $null)
            $success = $result.AsyncWaitHandle.WaitOne([TimeSpan]::FromSeconds(2))
            if ($success) {
                $client.EndConnect($result)
                $client.Close()
                return $true
            }
            return $false
        }
        catch {
            return $false
        }
    }

    [bool] IsOnline([string]$hostName) {
        try {
            return (Test-Connection -ComputerName $hostName -Count 1 -Quiet -ErrorAction SilentlyContinue)
        }
        catch {
            return $false
        }
    }
}
