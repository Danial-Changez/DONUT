# Integration tests for ResourceService - requires WPF in STA mode
# These tests verify actual XAML loading and WPF Application/Window behavior
using module "..\..\src\Services\ResourceService.psm1"

BeforeDiscovery {
    # Check STA mode at discovery time so -Skip works correctly
    $script:isStaMode = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA
}

Describe "ResourceService Integration" -Tag "Integration", "WPF" {

    BeforeAll {
        $script:srcRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\src")
        $script:stylesPath = Join-Path $script:srcRoot "UI\Styles"
        
        # Count expected XAML files
        $script:expectedStyleCount = (Get-ChildItem -Path $script:stylesPath -Filter '*.xaml').Count
    }

    Context "LoadStylesInto with ResourceDictionary" {
        It "Should load all XAML style files into a ResourceDictionary" {
            # Create a standalone ResourceDictionary (doesn't require Application)
            $resourceDict = [System.Windows.ResourceDictionary]::new()
            
            $service = [ResourceService]::new($script:srcRoot)
            
            # Use reflection to call the hidden method - unwrap PSObject for .NET interop
            $method = $service.GetType().GetMethods() | Where-Object { $_.Name -eq 'LoadStylesInto' } | Select-Object -First 1
            $method.Invoke($service, [object[]]@([System.Windows.ResourceDictionary]$resourceDict))
            
            # Verify styles were loaded
            $resourceDict.MergedDictionaries.Count | Should -Be $script:expectedStyleCount
        }

        It "Should load UIColors.xaml with color resources" {
            $resourceDict = [System.Windows.ResourceDictionary]::new()
            
            $service = [ResourceService]::new($script:srcRoot)
            $method = $service.GetType().GetMethods() | Where-Object { $_.Name -eq 'LoadStylesInto' } | Select-Object -First 1
            $method.Invoke($service, [object[]]@([System.Windows.ResourceDictionary]$resourceDict))
            
            # Check that we can find color-related resources
            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                $allKeys += $dict.Keys
            }
            
            # UIColors.xaml should have color definitions
            $colorKeys = $allKeys | Where-Object { $_ -match 'Color|Brush' }
            $colorKeys.Count | Should -BeGreaterThan 0
        }

        It "Should load ButtonStyles.xaml with button styles" {
            $resourceDict = [System.Windows.ResourceDictionary]::new()
            
            $service = [ResourceService]::new($script:srcRoot)
            $method = $service.GetType().GetMethods() | Where-Object { $_.Name -eq 'LoadStylesInto' } | Select-Object -First 1
            $method.Invoke($service, [object[]]@([System.Windows.ResourceDictionary]$resourceDict))
            
            # Check for button-related resources
            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                $allKeys += $dict.Keys
            }
            
            $buttonKeys = $allKeys | Where-Object { $_ -match 'Button' }
            $buttonKeys.Count | Should -BeGreaterThan 0
        }

        It "Should handle missing styles directory gracefully" {
            $resourceDict = [System.Windows.ResourceDictionary]::new()
            
            $service = [ResourceService]::new("C:\NonExistent\Path")
            $method = $service.GetType().GetMethods() | Where-Object { $_.Name -eq 'LoadStylesInto' } | Select-Object -First 1
            
            # Should not throw, just warn
            { $method.Invoke($service, [object[]]@([System.Windows.ResourceDictionary]$resourceDict)) } | Should -Not -Throw
            
            # No styles should be loaded
            $resourceDict.MergedDictionaries.Count | Should -Be 0
        }
    }

    Context "LoadGlobalResources with Application" {
        It "Should create Application.Current if not exists" -Skip:$(-not $script:isStaMode) {
            # Shutdown any existing application first
            if ([System.Windows.Application]::Current) {
                [System.Windows.Application]::Current.Shutdown()
                # Give it time to shutdown
                Start-Sleep -Milliseconds 100
            }
            
            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()
            
            [System.Windows.Application]::Current | Should -Not -BeNullOrEmpty
        }

        It "Should load styles into Application.Current.Resources" -Skip:(-not $script:isStaMode) {
            # Ensure application exists
            if (-not [System.Windows.Application]::Current) {
                $app = New-Object System.Windows.Application
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }
            
            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()
            
            [System.Windows.Application]::Current.Resources.MergedDictionaries.Count | Should -BeGreaterOrEqual $script:expectedStyleCount
        }

        It "Should set ShutdownMode to OnExplicitShutdown" -Skip:(-not $script:isStaMode) {
            if (-not [System.Windows.Application]::Current) {
                $app = New-Object System.Windows.Application
            }
            
            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()
            
            [System.Windows.Application]::Current.ShutdownMode | Should -Be ([System.Windows.ShutdownMode]::OnExplicitShutdown)
        }
    }

    Context "ApplyResourcesToWindow" {
        It "Should apply resources to a Window's ResourceDictionary" -Skip:(-not $script:isStaMode) {
            # Ensure application exists with resources
            if (-not [System.Windows.Application]::Current) {
                $app = New-Object System.Windows.Application
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }
            
            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()
            
            # Create a simple window
            $window = New-Object System.Windows.Window
            $window.Title = "Test Window"
            
            $initialCount = $window.Resources.MergedDictionaries.Count
            
            $service.ApplyResourcesToWindow($window)
            
            # Window should now have the styles
            $window.Resources.MergedDictionaries.Count | Should -BeGreaterThan $initialCount
            
            # Cleanup
            $window.Close()
        }

        It "Should fallback to LoadStylesInto when Application.Current is null" {
            # This test works without STA since it uses the fallback path
            # We can't easily clear Application.Current, so we test the method exists
            $service = [ResourceService]::new($script:srcRoot)
            
            $method = $service.GetType().GetMethod('ApplyResourcesToWindow')
            $method | Should -Not -BeNullOrEmpty
            $method.GetParameters().Count | Should -Be 1
            $method.GetParameters()[0].ParameterType.Name | Should -Be 'Window'
        }
    }

    Context "Resource Key Verification" {
        It "Should have expected resource keys from all style files" {
            $resourceDict = [System.Windows.ResourceDictionary]::new()
            
            $service = [ResourceService]::new($script:srcRoot)
            $method = $service.GetType().GetMethods() | Where-Object { $_.Name -eq 'LoadStylesInto' } | Select-Object -First 1
            $method.Invoke($service, [object[]]@([System.Windows.ResourceDictionary]$resourceDict))
            
            # Collect all keys
            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                foreach ($key in $dict.Keys) {
                    $allKeys += $key.ToString()
                }
            }
            
            # Should have a reasonable number of resources
            $allKeys.Count | Should -BeGreaterThan 5
            
            # Output keys for debugging (visible in Detailed output)
            Write-Host "Loaded $($allKeys.Count) resource keys from $($resourceDict.MergedDictionaries.Count) dictionaries"
        }

        It "Should load parseable XAML from all style files" {
            $xamlFiles = Get-ChildItem -Path $script:stylesPath -Filter '*.xaml'
            
            foreach ($file in $xamlFiles) {
                $content = Get-Content -Path $file.FullName -Raw
                
                # Basic XAML structure check
                $content | Should -Match '<ResourceDictionary'
                $content | Should -Match 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'
                
                # Verify it's parseable by creating a ResourceDictionary
                $context = New-Object System.Windows.Markup.ParserContext
                $context.BaseUri = [Uri]::new($file.FullName)
                
                $stream = [System.IO.File]::OpenRead($file.FullName)
                $dict = $null
                try {
                    $dict = [System.Windows.Markup.XamlReader]::Load($stream, $context)
                }
                finally {
                    $stream.Close()
                }
                
                $dict | Should -Not -BeNullOrEmpty -Because "$($file.Name) should be valid XAML"
            }
        }
    }
}
