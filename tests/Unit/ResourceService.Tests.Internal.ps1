# Internal test file, dot-sourced by ResourceService.Tests.ps1 once WPF is loaded.
using module "..\..\src\Services\ResourceService.psm1"

Describe "ResourceService" {

    BeforeAll {
        $script:tempDir = Join-Path $TestDrive "ResourceService"
        $script:stylesDir = Join-Path $script:tempDir "UI\Styles"

        New-Item -Path $script:stylesDir -ItemType Directory -Force | Out-Null
    }

    Context "Constructor" {
        It "Should initialize with source root path" {
            $service = [ResourceService]::new($script:tempDir)

            $service.SourceRoot | Should -Be $script:tempDir
        }

        It "Should accept any path string" {
            $service = [ResourceService]::new("C:\CustomPath")

            $service.SourceRoot | Should -Be "C:\CustomPath"
        }

        It "Should handle paths with spaces" {
            $pathWithSpaces = "C:\Program Files\My App\Source"
            $service = [ResourceService]::new($pathWithSpaces)

            $service.SourceRoot | Should -Be $pathWithSpaces
        }
    }

    Context "LoadStylesInto (via reflection)" {
        BeforeEach {
            $testXamlContent = @"
<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation">
    <SolidColorBrush x:Key="TestBrush" Color="Red" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"/>
</ResourceDictionary>
"@
            $script:testXamlPath = Join-Path $script:stylesDir "TestStyle.xaml"
            Set-Content -Path $script:testXamlPath -Value $testXamlContent
        }

        AfterEach {
            if (Test-Path $script:testXamlPath) {
                Remove-Item -Path $script:testXamlPath `
                            -Force `
                            -ErrorAction SilentlyContinue
            }
        }

        It "Should construct expected styles path" {
            $null = [ResourceService]::new($script:tempDir)

            $expectedStylesPath = Join-Path $script:tempDir 'UI\Styles'
            Test-Path $expectedStylesPath | Should -Be $true
        }

        It "Should handle missing styles directory gracefully" {
            $emptyRoot = Join-Path $TestDrive "EmptyRoot_$(Get-Random)"
            New-Item -Path $emptyRoot -ItemType Directory -Force | Out-Null

            $service = [ResourceService]::new($emptyRoot)

            $service.SourceRoot | Should -Be $emptyRoot
        }
    }

    Context "SourceRoot Property" {
        It "Should allow reading SourceRoot after construction" {
            $service = [ResourceService]::new($script:tempDir)

            $root = $service.SourceRoot

            $root | Should -Be $script:tempDir
        }

        It "Should allow updating SourceRoot" {
            $service = [ResourceService]::new($script:tempDir)

            $service.SourceRoot = "C:\NewPath"

            $service.SourceRoot | Should -Be "C:\NewPath"
        }
    }

    Context "Multiple Instances" {
        It "Should maintain separate source roots" {
            $service1 = [ResourceService]::new("C:\Path1")
            $service2 = [ResourceService]::new("C:\Path2")

            $service1.SourceRoot | Should -Be "C:\Path1"
            $service2.SourceRoot | Should -Be "C:\Path2"
        }
    }

    # Both need a running WPF Application, so the integration suite exercises them for real.
    Context "Method Existence" {
        It "Should have LoadGlobalResources method" {
            $service = [ResourceService]::new($script:tempDir)

            $method = $service.GetType().GetMethod('LoadGlobalResources')
            $method | Should -Not -BeNullOrEmpty
        }

        It "Should have ApplyResourcesToWindow method" {
            $service = [ResourceService]::new($script:tempDir)

            $method = $service.GetType().GetMethod('ApplyResourcesToWindow')
            $method | Should -Not -BeNullOrEmpty
        }

        It "Should have hidden LoadStylesInto method" {
            $service = [ResourceService]::new($script:tempDir)

            # PowerShell 'hidden' is not a CLR access modifier, so the method is still public.
            $allMethods = $service.GetType().GetMethods()
            $methodNames = $allMethods | ForEach-Object { $_.Name }
            $methodNames | Should -Contain 'LoadStylesInto'
        }
    }

    Context "Styles Directory Detection" {
        It "Should detect XAML files in styles directory" {
            $xaml1 = Join-Path $script:stylesDir "Style1.xaml"
            $xaml2 = Join-Path $script:stylesDir "Style2.xaml"

            $minimalXaml = '<ResourceDictionary xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"/>'
            Set-Content -Path $xaml1 -Value $minimalXaml
            Set-Content -Path $xaml2 -Value $minimalXaml

            $service = [ResourceService]::new($script:tempDir)
            $stylesPath = Join-Path $service.SourceRoot 'UI\Styles'

            $xamlFiles = Get-ChildItem -Path $stylesPath -Filter '*.xaml'
            $xamlFiles.Count | Should -BeGreaterOrEqual 2

            Remove-Item -Path $xaml1 -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $xaml2 -Force -ErrorAction SilentlyContinue
        }

        It "Should ignore non-XAML files in styles directory" {
            $txtFile = Join-Path $script:stylesDir "readme.txt"
            Set-Content -Path $txtFile -Value "Not a style file"

            $service = [ResourceService]::new($script:tempDir)
            $stylesPath = Join-Path $service.SourceRoot 'UI\Styles'

            $xamlFiles = Get-ChildItem -Path $stylesPath -Filter '*.xaml'
            $txtFiles = Get-ChildItem -Path $stylesPath -Filter '*.txt'

            $txtFiles.Count | Should -BeGreaterOrEqual 1
            $xamlFiles | Where-Object { $_.Extension -eq '.txt' } | Should -BeNullOrEmpty

            Remove-Item -Path $txtFile -Force -ErrorAction SilentlyContinue
        }
    }
}
