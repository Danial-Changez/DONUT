using module "..\..\src\Models\PersonLens.psm1"

Describe "PersonLens" {

    BeforeAll {
        $script:bundleJson = @'
{
  "upn": "jane.doe@corp.com",
  "sam": "U0001",
  "displayName": "Jane Doe",
  "email": "jane.doe@corp.com",
  "manager": "John Smith",
  "office": "100 MAIN STREET, SPRINGFIELD, ON, N0A 1A0",
  "devices": [
    { "name": "WS-1", "os": "Windows 11 Enterprise", "lastLogon": "2026-07-03T10:00:00Z", "domain": "prod.contoso.com",
      "model": "Latitude 5440", "serial": "ABC1234", "manufacturer": "Dell Inc.",
      "bitLockerKeys": [ { "password": "111-222", "created": "2026-05-01T00:00:00Z" }, { "password": "333-444", "created": "" } ] },
    { "name": "WS-2", "os": "", "lastLogon": "", "domain": "fabrikam.local", "note": "BitLocker not escrowed to AD",
      "bitLockerKeys": [] }
  ],
  "errors": []
}
'@
    }

    Context "FromJson / FromHashtable" {
        It "maps the user fields" {
            $p = [PersonLens]::FromJson($script:bundleJson)
            $p.Upn         | Should -Be 'jane.doe@corp.com'
            $p.Sam         | Should -Be 'U0001'
            $p.DisplayName | Should -Be 'Jane Doe'
            $p.Email       | Should -Be 'jane.doe@corp.com'
            $p.Manager     | Should -Be 'John Smith'
            $p.Office      | Should -Be '100 MAIN STREET, SPRINGFIELD, ON, N0A 1A0'
        }

        It "maps each device with its OS, last logon, domain and BitLocker keys" {
            $p = [PersonLens]::FromJson($script:bundleJson)
            $p.Devices.Count | Should -Be 2

            $d0 = $p.Devices[0]
            $d0.Name   | Should -Be 'WS-1'
            $d0.Os     | Should -Be 'Windows 11 Enterprise'
            $d0.LastLogon | Should -Be '2026-07-03T10:00:00.0000000Z'
            $d0.Domain | Should -Be 'prod.contoso.com'
            $d0.HasBitLocker() | Should -BeTrue
            $d0.BitLockerKeys.Count | Should -Be 2
            $d0.BitLockerKeys[0].Password | Should -Be '111-222'
            # ConvertFrom-Json coerces the stamp to [datetime], so NormalizeStamp must re-emit UTC.
            $d0.BitLockerKeys[0].Created  | Should -Be '2026-05-01T00:00:00.0000000Z'
            $d0.BitLockerKeys[1].Created  | Should -BeNullOrEmpty
        }

        It "maps model, serial and manufacturer from the hardware inventory" {
            $p = [PersonLens]::FromJson($script:bundleJson)
            $d0 = $p.Devices[0]
            $d0.Model        | Should -Be 'Latitude 5440'
            $d0.Serial       | Should -Be 'ABC1234'
            $d0.Manufacturer | Should -Be 'Dell Inc.'
        }

        It "leaves the hardware fields empty when the bundle omits them" {
            $p = [PersonLens]::FromJson($script:bundleJson)
            $d1 = $p.Devices[1]
            $d1.Model        | Should -BeNullOrEmpty
            $d1.Serial       | Should -BeNullOrEmpty
            $d1.Manufacturer | Should -BeNullOrEmpty
        }

        It "flags a device with no BitLocker and carries its note" {
            $p = [PersonLens]::FromJson($script:bundleJson)
            $d1 = $p.Devices[1]
            $d1.HasBitLocker() | Should -BeFalse
            $d1.BitLockerKeys.Count | Should -Be 0
            $d1.Note | Should -Be 'BitLocker not escrowed to AD'
        }

        It "returns an empty lens for a null hashtable" {
            $p = [PersonLens]::FromHashtable($null)
            $p.Upn | Should -BeNullOrEmpty
            $p.Devices.Count | Should -Be 0
            $p.Errors.Count | Should -Be 0
        }

        It "tolerates missing device / key collections" {
            $p = [PersonLens]::FromJson('{ "sam": "U9", "devices": [ { "name": "X" } ] }')
            $p.Sam | Should -Be 'U9'
            $p.Devices.Count | Should -Be 1
            $p.Devices[0].Name | Should -Be 'X'
            $p.Devices[0].BitLockerKeys.Count | Should -Be 0
            $p.Devices[0].Serial | Should -BeNullOrEmpty
        }

        It "carries the worker's error list" {
            $p = [PersonLens]::FromJson('{ "errors": [ "AD user: not found", "SCCM affinity: 404" ] }')
            $p.Errors.Count | Should -Be 2
            $p.Errors[0] | Should -Be 'AD user: not found'
        }

        It "returns an error lens on malformed JSON" {
            $p = [PersonLens]::FromJson('{ not json')
            $p.Errors.Count | Should -BeGreaterThan 0
            $p.Errors[0] | Should -BeLike '*parse*'
        }

        It "returns an empty lens for blank input" {
            $p = [PersonLens]::FromJson('')
            $p.Devices.Count | Should -Be 0
            $p.Errors.Count | Should -Be 0
        }
    }

    Context "LensDeployment.ParseBundle" {
        It "parses a software bundle into rows" {
            $json = '{"deployments":[{"software":"Zoom Workplace","collection":"Zoom Deploy - WASH",' +
            '"program":"Install - silent"}],"error":""}'
            $b = [LensDeployment]::ParseBundle($json)
            @($b.Rows).Count | Should-Be 1
            $b.Rows[0].Software | Should-Be 'Zoom Workplace'
            $b.Rows[0].Collection | Should-Be 'Zoom Deploy - WASH'
            $b.Rows[0].Program | Should-Be 'Install - silent'
            $b.Error | Should-Be ''
        }

        It "carries the bundle's error beside empty rows" {
            $b = [LensDeployment]::ParseBundle('{"deployments":[],"error":"SCCM software: 404"}')
            @($b.Rows).Count | Should-Be 0
            $b.Error | Should-Be 'SCCM software: 404'
        }

        It "turns malformed or blank JSON into the error or an empty bundle" {
            ([LensDeployment]::ParseBundle('{ not json').Error -match 'parse') | Should-BeTrue
            $blank = [LensDeployment]::ParseBundle('')
            @($blank.Rows).Count | Should-Be 0
            $blank.Error | Should-Be ''
        }
    }

    Context "FromError" {
        It "carries the message as the single error so the pane can show a reason" {
            $p = [PersonLens]::FromError('the lookup did not return within 90s')
            $p.Errors.Count | Should -Be 1
            $p.Errors[0] | Should -BeExactly 'the lookup did not return within 90s'
            $p.Devices.Count | Should -Be 0
            $p.Upn | Should -BeNullOrEmpty
        }

        It "leaves DisplayName settable so a caller can keep the picked name on screen" {
            $p = [PersonLens]::FromError('timed out')
            $p.DisplayName = 'Jane Doe'
            $p.DisplayName | Should -BeExactly 'Jane Doe'
            $p.Errors.Count | Should -Be 1
        }
    }

    Context "LensFormat.LogonLabel" {
        It "reads blank as 'no logon recorded'" {
            [LensFormat]::LogonLabel('') | Should -Be 'no logon recorded'
        }
        It "reads the epoch/min-value as 'no logon recorded'" {
            [LensFormat]::LogonLabel('0001-01-01T00:00:00') | Should -Be 'no logon recorded'
        }
        It "renders a real timestamp as a relative 'seen ...'" {
            $recent = ([datetime]::UtcNow.AddMinutes(-5)).ToString('o')
            [LensFormat]::LogonLabel($recent) | Should -BeLike 'seen *'
        }
    }
}
