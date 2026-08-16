<#
    Tests for ResolveWorker.ps1 - the fast lane's slim, class-free child.
    Dot-sources the script with no -ResultFile (functions load, nothing runs), stubs
    Resolve-DnsName (Windows-only cmdlet), and probes a real local TcpListener. The
    end-to-end case runs the actual script as a child pwsh and reads the verdict file.
#>
using module "..\..\src\Core\LogService.psm1"

Describe "ResolveWorker" {

    BeforeAll {
        $script:workerPath = [System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '../../src/Scripts/ResolveWorker.ps1'))
        $script:root = Join-Path $TestDrive 'DonutResolveWorker'
        New-Item -ItemType Directory -Force -Path $script:root | Out-Null

        # Load the functions only (no -ResultFile = the main body returns early).
        . $script:workerPath
        $script:log = [NullLogService]::new()
    }

    Context "Resolve-TargetIp" {
        It "returns the first A record's address" {
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                [pscustomobject]@{ IPAddress = '10.1.2.3' }
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server 'DC1' -Log $script:log | Should -Be '10.1.2.3'
        }

        It "returns '' when DNS has no answer (a verdict, not an error)" {
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                [pscustomobject]@{ NameHost = 'no-a-record' }   # nothing with an IPAddress
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server 'DC1' -Log $script:log | Should -Be ''
        }

        It "returns '' when the lookup throws" {
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                throw 'DNS server failure'
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server 'DC1' -Log $script:log | Should -Be ''
        }

        It "returns '' without querying when no DC is supplied" {
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                throw 'must not be called'
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server '' -Log $script:log | Should -Be ''
        }

        It "asks for the FQDN first when the pick's domain is known, and only that on a hit" {
            $script:asked = [System.Collections.Generic.List[string]]::new()
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                $script:asked.Add($Name)
                [pscustomobject]@{ IPAddress = '10.9.9.9' }
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server 'DC1' -Log $script:log -Domain 'sibling.local' |
                Should -Be '10.9.9.9'
            @($script:asked) | Should -Be @('PC1.sibling.local')
        }

        It "falls back to the bare name when the FQDN has no answer" {
            $script:asked = [System.Collections.Generic.List[string]]::new()
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                $script:asked.Add($Name)
                if ($Name -match '\.') { throw 'DNS name does not exist' }
                [pscustomobject]@{ IPAddress = '10.1.2.3' }
            }
            Resolve-TargetIp -TargetHost 'PC1' -Server 'DC1' -Log $script:log -Domain 'sibling.local' |
                Should -Be '10.1.2.3'
            @($script:asked) | Should -Be @('PC1.sibling.local', 'PC1')
        }

        It "never re-qualifies a name that already carries a dot" {
            $script:asked = [System.Collections.Generic.List[string]]::new()
            function script:Resolve-DnsName {
                [CmdletBinding()] param($Name, $Server, $Type)
                $script:asked.Add($Name)
                [pscustomobject]@{ IPAddress = '10.1.2.3' }
            }
            $null = Resolve-TargetIp -TargetHost 'pc1.corp.local' -Server 'DC1' -Log $script:log -Domain 'other.local'
            @($script:asked) | Should -Be @('pc1.corp.local')
        }
    }

    Context "Test-RpcPort" {
        It "is true against a listening port and false against a closed one" {
            $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
            $listener.Start()
            try {
                $open = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
                Test-RpcPort -Ip '127.0.0.1' -Log $script:log -Port $open | Should -BeTrue
            } finally { $listener.Stop() }

            # Nothing listens here anymore: refused connect -> $false, no throw.
            Test-RpcPort -Ip '127.0.0.1' -Log $script:log -Port $open | Should -BeFalse
        }
    }

    Context "end-to-end file protocol (real child pwsh)" {
        It "writes an empty-IP verdict with exit 0 when DNS cannot answer" {
            # Fake DC or missing Resolve-DnsName: both are DNS failures, reported as a verdict.
            $resultFile = Join-Path $script:root 'verdict.json'
            $pwsh = [System.Environment]::ProcessPath
            & $pwsh -NoProfile -NoLogo -NonInteractive -File $script:workerPath `
                -HostName 'PC1' -Dc 'no-such-dc.invalid' -LogsDir $script:root -ResultFile $resultFile

            $LASTEXITCODE | Should -Be 0
            $verdict = Get-Content -LiteralPath $resultFile -Raw | ConvertFrom-Json -AsHashtable
            $verdict.Mode | Should -Be 'Host'
            $verdict.HostName | Should -Be 'PC1'
            $verdict.Ip | Should -Be ''
            $verdict.Online | Should -BeFalse
        }
    }

    Context "static guards (the properties the fast lane exists for)" {
        It "ResolveWorker imports nothing beyond LogService (no worker graph)" {
            $text = Get-Content -LiteralPath $script:workerPath -Raw
            $imports = [regex]::Matches($text, '(?m)^\s*using module\s+"([^"]+)"')
            $imports.Count | Should -Be 1
            $imports[0].Groups[1].Value | Should -Match 'LogService'
        }

        It "ResolveProcessJob never touches the pool (no RunspaceManager reference)" {
            $jobPath = [System.IO.Path]::GetFullPath(
                (Join-Path $PSScriptRoot '../../src/Core/ResolveProcessJob.psm1'))
            Get-Content -LiteralPath $jobPath -Raw | Should -Not -Match 'RunspaceManager'
        }
    }
}
