using module "..\..\src\Services\PersonLensService.psm1"
using module "..\..\src\Models\PersonLens.psm1"

# Fakes the env-coupled de-elevation seam (RunLookupJson) so the parse wiring is testable
# off a domain - mirrors ActiveDirectoryService's overridable-seam pattern.
class FakeLensService : PersonLensService {
    [string] $Json = ''
    FakeLensService([string]$json) : base('site.example', 'C:\Src') { $this.Json = $json }
    [string] RunLookupJson([string]$identity) { return $this.Json }
}

# Overrides only agent startup, so the encrypted exchange loop runs against a
# TestDrive exchange dir with no scheduled task or live agent behind it.
class StubAgentLensService : PersonLensService {
    [string] $AgentError = ''
    StubAgentLensService() : base('site.example', 'C:\Src') {}
    [string] EnsureAgent() { return $this.AgentError }
}

Describe "PersonLensService" {

    It "constructs with site + source root" {
        $svc = [PersonLensService]::new('sccm01.contoso.com', 'C:\Src')
        $svc.SiteServer | Should -Be 'sccm01.contoso.com'
        $svc.SourceRoot | Should -Be 'C:\Src'
    }

    It "parses a worker bundle into a typed PersonLens (Lookup over the faked seam)" {
        $json = '{ "upn": "a@b.com", "sam": "U1", "devices": [ { "name": "PC-1", "bitLockerKeys": [ { "password": "k1", "created": "" } ] } ] }'
        $svc = [FakeLensService]::new($json)

        $lens = $svc.Lookup('a@b.com')

        $lens.Upn | Should -Be 'a@b.com'
        $lens.Sam | Should -Be 'U1'
        $lens.Devices.Count | Should -Be 1
        $lens.Devices[0].Name | Should -Be 'PC-1'
        $lens.Devices[0].HasBitLocker() | Should -BeTrue
    }

    It "surfaces a worker error bundle as PersonLens.Errors" {
        $svc = [FakeLensService]::new('{ "errors": [ "no interactive session" ] }')
        $lens = $svc.Lookup('a@b.com')
        $lens.Errors.Count | Should -Be 1
        $lens.Errors[0] | Should -Be 'no interactive session'
        $lens.Devices.Count | Should -Be 0
    }

    It "produces a parseable error bundle from ErrorBundle" {
        $json = [PersonLensService]::ErrorBundle('boom')
        $lens = [PersonLens]::FromJson($json)
        $lens.Errors.Count | Should -Be 1
        $lens.Errors[0] | Should -Be 'boom'
    }

    Context "exchange crypto (format shared with LensAgent.ps1)" {

        It "NewKeyIv returns 48 bytes (32 key + 16 IV) and differs per call" {
            $a = [PersonLensService]::NewKeyIv()
            $b = [PersonLensService]::NewKeyIv()
            $a.Length | Should -Be 48
            [Convert]::ToBase64String($a) | Should -Not -Be ([Convert]::ToBase64String($b))
        }

        It "round-trips a bundle through ProtectText/UnprotectText" {
            $keyIv = [PersonLensService]::NewKeyIv()
            $json = '{ "sam": "U1", "devices": [ { "bitLockerKeys": [ { "password": "111-222-333" } ] } ] }'
            $blob = [PersonLensService]::ProtectText($json, $keyIv)
            [PersonLensService]::UnprotectText($blob, $keyIv) | Should -Be $json
        }

        It "never leaks the plaintext (BitLocker key) into the ciphertext" {
            $keyIv = [PersonLensService]::NewKeyIv()
            $blob = [PersonLensService]::ProtectText('{ "password": "111-222-333-444" }', $keyIv)
            [System.Text.Encoding]::UTF8.GetString($blob) | Should -Not -Match '111-222-333-444'
        }

        It "tampered ciphertext never yields the original text" {
            $keyIv = [PersonLensService]::NewKeyIv()
            $json = '{ "sam": "U1" }'
            $blob = [PersonLensService]::ProtectText($json, $keyIv)
            $blob[0] = $blob[0] -bxor 0xFF
            $out = $null
            try { $out = [PersonLensService]::UnprotectText($blob, $keyIv) } catch { $out = $null }
            $out | Should -Not -Be $json
        }

        It "WriteEncrypted lands an atomic file the agent format decrypts (no plaintext on disk)" {
            $keyIv = [PersonLensService]::NewKeyIv()
            $path = Join-Path ([IO.Path]::GetTempPath()) ("lens-wire-" + [guid]::NewGuid().ToString('N') + ".bin")
            $json = '{ "identity": "jane@corp.com", "sam": "U0001", "siteServer": "s" }'
            try {
                [PersonLensService]::WriteEncrypted($path, $json, $keyIv)
                Test-Path -LiteralPath "$path.tmp" | Should -BeFalse   # rename cleaned the tmp up
                $blob = [IO.File]::ReadAllBytes($path)
                [System.Text.Encoding]::UTF8.GetString($blob) | Should -Not -Match 'jane@corp.com'
                [PersonLensService]::UnprotectText($blob, $keyIv) | Should -Be $json
            }
            finally {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    }

    It "coalesces a missing logger to the null logger" {
        ([PersonLensService]::new('site.example', 'C:\Src', $null)).Logger.GetType().Name |
            Should -Be 'NullLogService'
    }

    It "returns empty owner JSON for an empty machine list" {
        [StubAgentLensService]::new().RunOwnerLookupJson(@()) | Should -Be ''
    }

    Context "exchange round trip (stubbed agent, TestDrive exchange dir)" {

        BeforeEach {
            $script:savedProgramData = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        }

        AfterEach {
            $env:ProgramData = $script:savedProgramData
        }

        It "anchors the exchange under ProgramData" {
            [PersonLensService]::AgentDir() | Should -Be (Join-Path $env:ProgramData 'DONUT\lens-agent')
        }

        It "sweeps only stale per-lookup exchanges, never the live agent dir" {
            $root = Join-Path $env:ProgramData 'DONUT'
            foreach ($n in 'lens-agent', 'lens-stale', 'lens-fresh') {
                New-Item -ItemType Directory -Path (Join-Path $root $n) -Force | Out-Null
            }
            # Even a stale-aged agent dir survives; only per-lookup lens-* dirs sweep.
            (Get-Item (Join-Path $root 'lens-stale')).LastWriteTime = (Get-Date).AddMinutes(-30)
            (Get-Item (Join-Path $root 'lens-agent')).LastWriteTime = (Get-Date).AddMinutes(-30)

            [PersonLensService]::SweepStaleExchanges(15)

            Test-Path (Join-Path $root 'lens-stale') | Should -BeFalse
            Test-Path (Join-Path $root 'lens-agent') | Should -BeTrue
            Test-Path (Join-Path $root 'lens-fresh') | Should -BeTrue
        }

        It "wraps an agent startup failure as a parseable error bundle" {
            $svc = [StubAgentLensService]::new()
            $svc.AgentError = 'no interactive desktop session.'

            $out = $svc.ExchangeRoundTrip(@{ kind = 'owner' }, $false)

            $out | Should -BeLike '*Lens agent unavailable*no interactive desktop session*'
            ([PersonLens]::FromJson($out)).Errors.Count | Should -Be 1
        }

        It "reports a missing session key rather than hanging" {
            $svc = [StubAgentLensService]::new()
            New-Item -ItemType Directory -Path ([PersonLensService]::AgentDir()) -Force | Out-Null

            $out = $svc.ExchangeRoundTrip(@{ identity = 'a@b.com' }, $true)

            $out | Should -BeLike '*session key is missing*'
        }

        It "times out cleanly and consumes this lookup's request file" {
            $svc = [StubAgentLensService]::new()
            $svc.TimeoutSec = 0
            $dir = [PersonLensService]::AgentDir()
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $dir 'key.bin'), [PersonLensService]::NewKeyIv())

            $out = $svc.ExchangeRoundTrip(@{ identity = 'a@b.com' }, $true)

            $out | Should -BeLike '*did not complete within 0s*'
            @(Get-ChildItem -Path $dir -Filter 'request-*.bin') | Should -BeNullOrEmpty
            Test-Path (Join-Path $dir 'key.bin') | Should -BeTrue   # only its own files go
        }

        It "completes a full encrypted round trip (with a partial) against a faked agent" {
            $svc = [StubAgentLensService]::new()
            $svc.TimeoutSec = 10
            $dir = [PersonLensService]::AgentDir()
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            $keyIv = [PersonLensService]::NewKeyIv()
            [IO.File]::WriteAllBytes((Join-Path $dir 'key.bin'), $keyIv)
            $response = '{ "sam": "U1", "devices": [] }'

            # A minimal in-process agent: waits for request-<id>, then answers in the
            # wire format (AES-256-CBC, tmp + rename) - partial first, then the result.
            $agent = [powershell]::Create()
            [void]$agent.AddScript({
                    param($dir, $keyIv, $response)
                    $deadline = (Get-Date).AddSeconds(8)
                    $req = $null
                    while ((Get-Date) -lt $deadline -and -not $req) {
                        $req = Get-ChildItem -Path $dir -Filter 'request-*.bin' -File -ErrorAction SilentlyContinue |
                            Select-Object -First 1
                        if (-not $req) { Start-Sleep -Milliseconds 50 }
                    }
                    if (-not $req) { return }
                    $id = $req.BaseName.Substring('request-'.Length)
                    $aes = [System.Security.Cryptography.Aes]::Create()
                    try {
                        $aes.Key = [byte[]]($keyIv[0..31]); $aes.IV = [byte[]]($keyIv[32..47])
                        foreach ($msg in @(@{ name = "partial-$id-1.bin"; text = '{ "sam": "U1" }' },
                                @{ name = "result-$id.bin"; text = $response })) {
                            $enc = $aes.CreateEncryptor()
                            $plain = [System.Text.Encoding]::UTF8.GetBytes($msg.text)
                            $tmp = Join-Path $dir ($msg.name + '.tmp')
                            [IO.File]::WriteAllBytes($tmp, $enc.TransformFinalBlock($plain, 0, $plain.Length))
                            Move-Item -LiteralPath $tmp -Destination (Join-Path $dir $msg.name) -Force
                            Start-Sleep -Milliseconds 120
                        }
                    }
                    finally { $aes.Dispose() }
                })
            [void]$agent.AddArgument($dir).AddArgument($keyIv).AddArgument($response)
            $handle = $agent.BeginInvoke()
            try {
                $out = $svc.ExchangeRoundTrip(@{ identity = 'jane@corp.example'; sam = 'U1' }, $true)

                $out | Should -Be $response
                @(Get-ChildItem -Path $dir -Filter '*-*.bin' -Exclude 'key.bin') |
                    Should -BeNullOrEmpty   # request, partial and result all consumed
            }
            finally {
                if (-not $handle.IsCompleted) { $agent.Stop() }
                $agent.Dispose()
            }
        }
    }
}
