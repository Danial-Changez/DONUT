using module "..\..\src\Services\SelfUpdateService.psm1"

Describe "SelfUpdateService" {
    
    Context "Token Management" {
        
        It "Saves and retrieves a token successfully" {
            $testTokenFile = Join-Path $TestDrive "GitHub_Token.json"
            $service = [SelfUpdateService]::new()
            $service.TokenFile = $testTokenFile
            
            $fakeTokenData = [PSCustomObject]@{
                access_token = "ghp_fake_token_123"
                scope        = "repo"
                token_type   = "bearer"
            }

            # Test Save
            $service.SaveToken($fakeTokenData)
            Test-Path $testTokenFile | Should -Be $true

            # Test Retrieve
            $retrievedToken = $service.GetStoredToken()
            $retrievedToken | Should -Be "ghp_fake_token_123"
        }

        It "Returns null if token file does not exist" {
            $service = [SelfUpdateService]::new()
            $service.TokenFile = "C:\NonExistent\Path\token.json"
            
            $result = $service.GetStoredToken()
            $result | Should -BeNullOrEmpty
        }
    }

    Context "GitHub API Interaction" {
        
        It "Initiates Device Flow correctly" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()
                
                Mock Invoke-RestMethod {
                    return [PSCustomObject]@{
                        device_code      = "fake_device_code"
                        user_code        = "1234-5678"
                        verification_uri = "https://github.com/login/device"
                    }
                } -ParameterFilter { 
                    $Uri -eq "https://github.com/login/device/code" -and $Method -eq "Post" 
                }

                $result = $service.InitiateDeviceFlow()
                $result.device_code | Should -Be "fake_device_code"
                $result.user_code | Should -Be "1234-5678"
            }
        }

        It "Polls for token and returns result" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Invoke-RestMethod {
                    return [PSCustomObject]@{
                        access_token = "ghp_new_token"
                    }
                } -ParameterFilter {
                    $Uri -eq "https://github.com/login/oauth/access_token" -and $Body.device_code -eq "code123"
                }

                $result = $service.PollForToken("code123")
                $result.access_token | Should -Be "ghp_new_token"
            }
        }

        It "GetLatestRelease calls correct endpoint" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Invoke-RestMethod {
                    return [PSCustomObject]@{
                        tag_name = "v1.0.0"
                        assets   = @()
                    }
                } -ParameterFilter {
                    $Uri -like "*releases/latest" -and $Headers.Authorization -eq "token my_token"
                }

                $result = $service.GetLatestRelease("my_token")
                $result.tag_name | Should -Be "v1.0.0"
            }
        }
    }

    Context "Asset Management" {
        
        It "Finds the correct asset by pattern" {
            $service = [SelfUpdateService]::new()
            $release = [PSCustomObject]@{
                assets = @(
                    [PSCustomObject]@{ name = "DONUT.msi"; url = "http://url/msi" },
                    [PSCustomObject]@{ name = "DONUT.zip"; url = "http://url/zip" }
                )
            }

            $asset = $service.GetReleaseAsset($release, "*.msi")
            $asset.name | Should -Be "DONUT.msi"
        }

        It "Downloads asset to destination" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Invoke-RestMethod { } 
                Mock New-Item { } -ParameterFilter { $ItemType -eq "Directory" }

                $asset = [PSCustomObject]@{ name = "file.txt"; url = "http://url/file" }
                $dest = Join-Path $TestDrive "Downloads"
                
                $path = $service.DownloadAsset("token", $asset, $dest)
                
                $path | Should -Be (Join-Path $dest "file.txt")
                Assert-MockCalled Invoke-RestMethod -Times 1
            }
        }
    }

    Context "Version Detection" {
        
        It "Detects version from Registry" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $true } -ParameterFilter { $Path -like "*Uninstall*" }
                Mock Get-ChildItem { return @([PSCustomObject]@{ PSPath = "HKLM:\...\Key1" }) }
                Mock Get-ItemProperty {
                    return [PSCustomObject]@{
                        DisplayName    = "DONUT"
                        Publisher      = "Bakery"
                        DisplayVersion = "1.7.0"
                    }
                }

                $version = $service.GetLocalVersion()
                $version.ToString() | Should -Be "1.7.0"
            }
        }

        It "Falls back to version file when registry entry not found" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                # No registry match
                Mock Test-Path { return $false } -ParameterFilter { $Path -like "*Uninstall*" }
                
                # Version file exists
                $versionFile = Join-Path $env:LOCALAPPDATA "DONUT\version.txt"
                Mock Test-Path { return $true } -ParameterFilter { $Path -eq $versionFile }
                Mock Get-Content { return "2.0.1" } -ParameterFilter { $Path -eq $versionFile }

                $version = $service.GetLocalVersion()
                $version.ToString() | Should -Be "2.0.1"
            }
        }

        It "Returns 0.0.0.0 when no version source available" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $false }

                $version = $service.GetLocalVersion()
                $version.ToString() | Should -Be "0.0.0.0"
            }
        }

        It "Skips registry entries without DONUT in DisplayName" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $true } -ParameterFilter { $Path -like "*Uninstall*" }
                Mock Get-ChildItem { return @([PSCustomObject]@{ PSPath = "HKLM:\...\Key1" }) }
                Mock Get-ItemProperty {
                    return [PSCustomObject]@{
                        DisplayName    = "Other Application"
                        Publisher      = "Other Company"
                        DisplayVersion = "9.9.9"
                    }
                }
                
                # Fallback version file doesn't exist
                $versionFile = Join-Path $env:LOCALAPPDATA "DONUT\version.txt"
                Mock Test-Path { return $false } -ParameterFilter { $Path -eq $versionFile }

                $version = $service.GetLocalVersion()
                $version.ToString() | Should -Be "0.0.0.0"
            }
        }
    }

    Context "Update Application" {
    
        It "Verifies file hash correctly" {
            $service = [SelfUpdateService]::new()
            $file = Join-Path $TestDrive "test.txt"
            Set-Content $file "content"
            $hash = (Get-FileHash $file -Algorithm SHA256).Hash

            $service.VerifyFileHash($file, $hash) | Should -Be $true
            $service.VerifyFileHash($file, "WRONGHASH") | Should -Be $false
        }

        It "Returns false for non-existent file" {
            $service = [SelfUpdateService]::new()
            
            $result = $service.VerifyFileHash("C:\NonExistent\file.msi", "SOMEHASH")
            
            $result | Should -Be $false
        }

        It "Launches InstallWorker via Start-Process" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $true }
                Mock Copy-Item { }
                Mock Start-Process { }

                $service.ApplyUpdate("C:\Temp\DONUT.msi", $false, "C:\Source")

                Assert-MockCalled Start-Process -Times 1 -ParameterFilter { 
                    $FilePath -eq "powershell.exe" -and 
                    $ArgumentList -match "InstallWorker.ps1" -and
                    $ArgumentList -match "-MsiPath"
                }
            }
        }

        It "Includes -Rollback flag when IsRollback is true" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $true }
                Mock Copy-Item { }
                Mock Start-Process { }

                $service.ApplyUpdate("C:\Temp\DONUT.msi", $true, "C:\Source")

                Assert-MockCalled Start-Process -Times 1 -ParameterFilter { 
                    $ArgumentList -match "-Rollback"
                }
            }
        }

        It "Throws when InstallWorker.ps1 not found" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Test-Path { return $false }

                { $service.ApplyUpdate("C:\Temp\DONUT.msi", $false, "C:\NonExistent") } | Should -Throw "*InstallWorker.ps1 not found*"
            }
        }
    }

    Context "GetStoredToken Error Handling" {
        It "Returns null when token file is corrupted" {
            $service = [SelfUpdateService]::new()
            $corruptFile = Join-Path $TestDrive "corrupt_token.json"
            
            # Write non-DPAPI-encrypted garbage
            [IO.File]::WriteAllBytes($corruptFile, [byte[]](1,2,3,4,5))
            $service.TokenFile = $corruptFile

            $result = $service.GetStoredToken()
            
            $result | Should -BeNullOrEmpty
        }
    }

    Context "PollForToken Error Handling" {
        It "Returns null when API returns error" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Invoke-RestMethod {
                    return [PSCustomObject]@{
                        error = "authorization_pending"
                    }
                }

                $result = $service.PollForToken("pending_code")
                $result | Should -BeNullOrEmpty
            }
        }

        It "Returns null when API call throws" {
            InModuleScope "SelfUpdateService" {
                $service = [SelfUpdateService]::new()

                Mock Invoke-RestMethod { throw "Network error" }

                $result = $service.PollForToken("error_code")
                $result | Should -BeNullOrEmpty
            }
        }
    }

    Context "GetReleaseAsset Edge Cases" {
        It "Returns null when no asset matches pattern" {
            $service = [SelfUpdateService]::new()
            $release = [PSCustomObject]@{
                assets = @(
                    [PSCustomObject]@{ name = "DONUT.zip"; url = "http://url/zip" }
                )
            }

            $asset = $service.GetReleaseAsset($release, "*.exe")
            $asset | Should -BeNullOrEmpty
        }

        It "Returns null when assets array is empty" {
            $service = [SelfUpdateService]::new()
            $release = [PSCustomObject]@{
                assets = @()
            }

            $asset = $service.GetReleaseAsset($release, "*.msi")
            $asset | Should -BeNullOrEmpty
        }
    }
}
