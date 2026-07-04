using module "..\..\src\Services\PersonLensService.psm1"
using module "..\..\src\Models\PersonLens.psm1"

# Fakes the env-coupled de-elevation seam (RunLookupJson) so the parse wiring is testable
# off a domain - mirrors ActiveDirectoryService's overridable-seam pattern.
class FakeLensService : PersonLensService {
    [string] $Json = ''
    FakeLensService([string]$json) : base('site.example', 'C:\Src') { $this.Json = $json }
    [string] RunLookupJson([string]$identity) { return $this.Json }
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
}
