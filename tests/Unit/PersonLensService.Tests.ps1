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
}
