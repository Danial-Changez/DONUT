# Decision logic only: the side-effecting installers need a real elevated first launch.
if (-not ('Donut.Launcher.Bootstrap' -as [type])) {
    # -ReferencedAssemblies replaces Add-Type's default set, and SMA resolves by path only.
    Add-Type -Path "$PSScriptRoot\..\..\src\Launcher\Bootstrap.cs" -ReferencedAssemblies @(
        'netstandard', 'System.Runtime', 'System.Collections', 'System.Memory',
        'System.Windows.Forms', 'System.Net.Http', 'System.IO.Compression',
        'System.IO.Compression.ZipFile', 'System.Text.Json', 'System.Linq',
        'System.Security.Principal.Windows', 'System.Security.Claims',
        'System.Security.Cryptography', 'System.ComponentModel.Primitives',
        'System.Diagnostics.Process', 'System.Text.RegularExpressions',
        ([psobject].Assembly.Location)
    )
}

Describe 'Bootstrap.FindOnPath' {
    BeforeAll {
        $script:dir = Join-Path ([IO.Path]::GetTempPath()) "donut-bootstrap-test-$PID"
        New-Item -ItemType Directory -Path $script:dir -Force | Out-Null
        Set-Content -Path (Join-Path $script:dir 'present.exe') -Value ''
    }
    AfterAll {
        Remove-Item $script:dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'resolves an exe that exists on the search path' {
        [Donut.Launcher.Bootstrap]::FindOnPath('present.exe', "C:\nowhere;$script:dir") |
            Should -Be (Join-Path $script:dir 'present.exe')
    }

    It 'returns null when the exe is absent' {
        [Donut.Launcher.Bootstrap]::FindOnPath('absent.exe', "C:\nowhere;$script:dir") |
            Should -BeNullOrEmpty
    }

    It 'tolerates quoted and junk PATH entries' {
        $path = "`"$script:dir`";C:\bad<>|entry"
        [Donut.Launcher.Bootstrap]::FindOnPath('present.exe', $path) |
            Should -Be (Join-Path $script:dir 'present.exe')
    }
}

Describe 'Bootstrap.SelectPwshAsset' {
    It 'picks the win-x64 MSI from a release document' {
        $json = @'
{ "assets": [
  { "name": "PowerShell-7.5.4-win-arm64.msi", "browser_download_url": "https://example.test/arm" },
  { "name": "PowerShell-7.5.4-win-x64.zip",   "browser_download_url": "https://example.test/zip" },
  { "name": "PowerShell-7.5.4-win-x64.msi",   "browser_download_url": "https://example.test/x64" }
] }
'@
        [Donut.Launcher.Bootstrap]::SelectPwshAsset($json) | Should -Be 'https://example.test/x64'
    }

    It 'returns null when no matching asset exists' {
        $json = '{ "assets": [ { "name": "hashes.sha256", "browser_download_url": "u" } ] }'
        [Donut.Launcher.Bootstrap]::SelectPwshAsset($json) | Should -BeNullOrEmpty
    }
}

Describe 'Bootstrap.SelectWizTreeAsset' {
    It 'picks the portable zip and ignores the setup exe' {
        $html = @'
<a href="files/wiztree_4_32_setup.exe">DOWNLOAD INSTALLER</a>
<a href="files/wiztree_4_32_portable.zip">DOWNLOAD PORTABLE</a>
'@
        [Donut.Launcher.Bootstrap]::SelectWizTreeAsset($html) |
            Should -Be 'https://diskanalyzer.com/files/wiztree_4_32_portable.zip'
    }

    It 'matches a three-part version' {
        $html = '<a href="files/wiztree_4_32_1_portable.zip">x</a>'
        [Donut.Launcher.Bootstrap]::SelectWizTreeAsset($html) |
            Should -Be 'https://diskanalyzer.com/files/wiztree_4_32_1_portable.zip'
    }

    It 'returns null when the page carries no portable link' {
        [Donut.Launcher.Bootstrap]::SelectWizTreeAsset('<a href="files/other.zip">x</a>') |
            Should -BeNullOrEmpty
    }
}

Describe 'Bootstrap.WizTreePath' {
    It 'resolves where DeployWizTree looks for the scanner' {
        [Donut.Launcher.Bootstrap]::WizTreePath('C:\app') |
            Should -Be 'C:\app\src\Tools\wiztree64.exe'
    }
}
