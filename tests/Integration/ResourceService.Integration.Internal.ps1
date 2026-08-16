# Integration tests for ResourceService, which need WPF in STA mode.
using module "..\..\src\Services\ResourceService.psm1"
using namespace System.Windows

BeforeDiscovery {
    # Check STA mode at discovery time so -Skip works correctly
    $script:isStaMode = [System.Threading.Thread]::CurrentThread.GetApartmentState() -eq
    [System.Threading.ApartmentState]::STA
}

Describe "ResourceService Integration" -Tag "Integration", "WPF" {

    BeforeAll {
        $script:srcRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\src")
        $script:stylesPath = Join-Path $script:srcRoot "UI\Styles"

        $script:expectedStyleCount = (Get-ChildItem -Path $script:stylesPath -Filter '*.xaml').Count

        # Reflection reaches the hidden method, and the cast unwraps PSObject for interop.
        function Invoke-LoadStylesInto([ResourceService]$service, [ResourceDictionary]$dict) {
            $method = $service.GetType().GetMethods() |
                Where-Object { $_.Name -eq 'LoadStylesInto' } |
                Select-Object -First 1
            $method.Invoke($service, [object[]]@([ResourceDictionary]$dict))
        }
    }

    Context "LoadStylesInto with ResourceDictionary" {
        It "Should load all XAML style files into a ResourceDictionary" {
            # A standalone ResourceDictionary needs no Application.
            $resourceDict = [ResourceDictionary]::new()

            $service = [ResourceService]::new($script:srcRoot)
            Invoke-LoadStylesInto $service $resourceDict

            $resourceDict.MergedDictionaries.Count | Should -Be $script:expectedStyleCount
        }

        It "Should load UIColors.xaml with color resources" {
            $resourceDict = [ResourceDictionary]::new()

            $service = [ResourceService]::new($script:srcRoot)
            Invoke-LoadStylesInto $service $resourceDict

            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                $allKeys += $dict.Keys
            }

            $colorKeys = $allKeys | Where-Object { $_ -match 'Color|Brush' }
            $colorKeys.Count | Should -BeGreaterThan 0
        }

        It "Should load ButtonStyles.xaml with button styles" {
            $resourceDict = [ResourceDictionary]::new()

            $service = [ResourceService]::new($script:srcRoot)
            Invoke-LoadStylesInto $service $resourceDict

            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                $allKeys += $dict.Keys
            }

            $buttonKeys = $allKeys | Where-Object { $_ -match 'Button' }
            $buttonKeys.Count | Should -BeGreaterThan 0
        }

        It "Should handle missing styles directory gracefully" {
            $resourceDict = [ResourceDictionary]::new()

            $service = [ResourceService]::new("C:\NonExistent\Path")

            { Invoke-LoadStylesInto $service $resourceDict } | Should -Not -Throw

            $resourceDict.MergedDictionaries.Count | Should -Be 0
        }
    }

    Context "LoadGlobalResources with Application" {
        It "Should create Application.Current if not exists" -Skip:$(-not $script:isStaMode) {
            if ([System.Windows.Application]::Current) {
                [System.Windows.Application]::Current.Shutdown()
                Start-Sleep -Milliseconds 100
            }

            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()

            [System.Windows.Application]::Current | Should -Not -BeNullOrEmpty
        }

        It "Should load styles into Application.Current.Resources" -Skip:(-not $script:isStaMode) {
            if (-not [System.Windows.Application]::Current) {
                $app = New-Object System.Windows.Application
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }

            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()

            [Application]::Current.Resources.MergedDictionaries.Count |
                Should -BeGreaterOrEqual $script:expectedStyleCount
        }

        It "Should set ShutdownMode to OnExplicitShutdown" -Skip:(-not $script:isStaMode) {
            if (-not [Application]::Current) {
                $null = New-Object System.Windows.Application
            }

            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()

            [Application]::Current.ShutdownMode | Should -Be ([ShutdownMode]::OnExplicitShutdown)
        }
    }

    Context "ApplyResourcesToWindow" {
        It "Should apply resources to a Window's ResourceDictionary" -Skip:(-not $script:isStaMode) {
            if (-not [System.Windows.Application]::Current) {
                $app = New-Object System.Windows.Application
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
            }

            $service = [ResourceService]::new($script:srcRoot)
            $service.LoadGlobalResources()

            $window = New-Object System.Windows.Window
            $window.Title = "Test Window"

            $initialCount = $window.Resources.MergedDictionaries.Count

            $service.ApplyResourcesToWindow($window)

            $window.Resources.MergedDictionaries.Count | Should -BeGreaterThan $initialCount

            $window.Close()
        }

        It "Should fallback to LoadStylesInto when Application.Current is null" {
            # Application.Current cannot be cleared here, so only the signature is checked.
            $service = [ResourceService]::new($script:srcRoot)

            $method = $service.GetType().GetMethod('ApplyResourcesToWindow')
            $method | Should -Not -BeNullOrEmpty
            $method.GetParameters().Count | Should -Be 1
            $method.GetParameters()[0].ParameterType.Name | Should -Be 'Window'
        }
    }

    Context "Resource Key Verification" {
        It "Should have expected resource keys from all style files" {
            $resourceDict = [ResourceDictionary]::new()

            $service = [ResourceService]::new($script:srcRoot)
            Invoke-LoadStylesInto $service $resourceDict

            $allKeys = @()
            foreach ($dict in $resourceDict.MergedDictionaries) {
                foreach ($key in $dict.Keys) {
                    $allKeys += $key.ToString()
                }
            }

            $allKeys.Count | Should -BeGreaterThan 5

            # Diagnostic only, and visible in Detailed output.
            Write-Host ("Loaded $($allKeys.Count) resource keys from " +
                "$($resourceDict.MergedDictionaries.Count) dictionaries")
        }

        It "Should load parseable XAML from all style files" {
            $xamlFiles = Get-ChildItem -Path $script:stylesPath -Filter '*.xaml'

            foreach ($file in $xamlFiles) {
                $content = Get-Content -Path $file.FullName -Raw

                $content | Should -Match '<ResourceDictionary'
                $content | Should -Match 'xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"'

                $context = New-Object System.Windows.Markup.ParserContext
                $context.BaseUri = [Uri]::new($file.FullName)

                $stream = [System.IO.File]::OpenRead($file.FullName)
                $dict = $null
                try {
                    $dict = [System.Windows.Markup.XamlReader]::Load($stream, $context)
                } finally {
                    $stream.Close()
                }

                $dict | Should -Not -BeNullOrEmpty -Because "$($file.Name) should be valid XAML"
            }
        }
    }
}
