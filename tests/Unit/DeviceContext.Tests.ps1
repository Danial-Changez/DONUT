using module "..\..\src\Models\DeviceContext.psm1"

Describe "DeviceContext" {

    Context "Constructor" {
        It "Should initialize with hostname" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.HostName | Should -Be "TestHost"
        }

        It "Should default IsOnline to false" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.IsOnline | Should -Be $false
        }

        It "Should default StatusMessage to 'Initialized'" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.StatusMessage | Should -Be "Initialized"
        }

        It "Should have null IPAddress initially" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.IPAddress | Should -BeNullOrEmpty
        }

        It "Should handle empty hostname" {
            $device = [DeviceContext]::new("")
            
            $device.HostName | Should -Be ""
            $device.IsOnline | Should -Be $false
        }

        It "Should handle hostname with spaces" {
            $device = [DeviceContext]::new("Test Host Name")
            
            $device.HostName | Should -Be "Test Host Name"
        }
    }

    Context "Property Mutation" {
        It "Should allow setting IPAddress" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.IPAddress = "192.168.1.100"
            
            $device.IPAddress | Should -Be "192.168.1.100"
        }

        It "Should allow setting IsOnline to true" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.IsOnline = $true
            
            $device.IsOnline | Should -Be $true
        }

        It "Should allow updating StatusMessage" {
            $device = [DeviceContext]::new("TestHost")
            
            $device.StatusMessage = "Scanning..."
            
            $device.StatusMessage | Should -Be "Scanning..."
        }

        It "Should allow updating HostName" {
            $device = [DeviceContext]::new("OldHost")
            
            $device.HostName = "NewHost"
            
            $device.HostName | Should -Be "NewHost"
        }
    }

    Context "Multiple Instances" {
        It "Should maintain separate state for different instances" {
            $device1 = [DeviceContext]::new("Host1")
            $device2 = [DeviceContext]::new("Host2")
            
            $device1.IsOnline = $true
            $device1.IPAddress = "10.0.0.1"
            
            $device2.IsOnline = $false
            $device2.IPAddress = "10.0.0.2"
            
            $device1.HostName | Should -Be "Host1"
            $device1.IsOnline | Should -Be $true
            $device1.IPAddress | Should -Be "10.0.0.1"
            
            $device2.HostName | Should -Be "Host2"
            $device2.IsOnline | Should -Be $false
            $device2.IPAddress | Should -Be "10.0.0.2"
        }
    }

    Context "Typical Workflow" {
        It "Should support typical device status lifecycle" {
            $device = [DeviceContext]::new("WORKSTATION01")
            
            # Initial state
            $device.StatusMessage | Should -Be "Initialized"
            $device.IsOnline | Should -Be $false
            
            # After network probe
            $device.IPAddress = "192.168.1.50"
            $device.IsOnline = $true
            $device.StatusMessage = "Online"
            
            $device.IPAddress | Should -Be "192.168.1.50"
            $device.IsOnline | Should -Be $true
            $device.StatusMessage | Should -Be "Online"
            
            # During scan
            $device.StatusMessage = "Scanning for updates..."
            $device.StatusMessage | Should -Be "Scanning for updates..."
            
            # After completion
            $device.StatusMessage = "Completed - 5 updates found"
            $device.StatusMessage | Should -Be "Completed - 5 updates found"
        }
    }
}
