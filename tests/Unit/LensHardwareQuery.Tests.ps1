Describe "Lens hardware inventory query" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] bind lives inside a function body.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:HwScript = $script:HardwareScript
        $script:Pair = @{ name = 'WS-1'; resourceId = '16777345' }

        # An OData collection answer. An empty one is how a site rejects the filter shape
        # without erroring, which is the case that used to blank the card in silence.
        function New-Collection { param($Rows) return [pscustomobject]@{ value = @($Rows) } }
    }

    Context "the filter form works" {

        It "fills model, manufacturer and serial without touching the keyed segment" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'COMPUTER_SYSTEM') {
                    return New-Collection @([pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7450' })
                }
                return New-Collection @([pscustomobject]@{ SerialNumber = '9XKQ2Z3' })
            }

            $rows = @(& $script:HwScript 'sccm.corp.com' $script:Pair)

            $rows.Count | Should -Be 1
            $rows[0].model | Should -Be 'Latitude 7450'
            $rows[0].manufacturer | Should -Be 'Dell Inc.'
            $rows[0].serial | Should -Be '9XKQ2Z3'
            $rows[0].error | Should -BeNullOrEmpty
            # The per-device wall time feeds the stage marks debug logging prints.
            ($rows[0].ms -ge 0) | Should-BeTrue
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
            Should -Not -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match '\(16777345\)' }
        }
    }

    Context "the filter form answers 200 with an empty set" {

        It "falls back to the keyed segment instead of blanking the row" {
            Mock Invoke-RestMethod {
                # Only the keyed segment carries the id in a parenthesised path segment.
                if ($Uri -notmatch '\(16777345\)') { return New-Collection @() }
                if ($Uri -match 'COMPUTER_SYSTEM') {
                    return [pscustomobject]@{ Manufacturer = 'Dell Inc.'; Model = 'Latitude 7450' }
                }
                return [pscustomobject]@{ SerialNumber = '9XKQ2Z3' }
            }

            $rows = @(& $script:HwScript 'sccm.corp.com' $script:Pair)

            $rows[0].model | Should -Be 'Latitude 7450'
            $rows[0].serial | Should -Be '9XKQ2Z3'
            $rows[0].error | Should -BeNullOrEmpty
        }
    }

    Context "neither form returns a row" {

        It "names the reason rather than reporting a silent blank" {
            Mock Invoke-RestMethod { return New-Collection @() }

            $rows = @(& $script:HwScript 'sccm.corp.com' $script:Pair)

            $rows[0].model | Should -BeNullOrEmpty
            $rows[0].serial | Should -BeNullOrEmpty
            $rows[0].error | Should -Match 'no inventory rows for ResourceID 16777345'
        }

        It "carries the filter form's own failure when it threw" {
            Mock Invoke-RestMethod {
                if ($Uri -notmatch '\(16777345\)') { throw 'Response status code does not indicate success: 404 (Not Found).' }
                return New-Collection @()
            }

            $rows = @(& $script:HwScript 'sccm.corp.com' $script:Pair)

            $rows[0].error | Should -Match '404'
        }
    }

    Context "the affinity rows carried no ResourceID" {

        It "says so and never calls the AdminService" {
            Mock Invoke-RestMethod { throw 'should not be reached' }

            $rows = @(& $script:HwScript 'sccm.corp.com' @{ name = 'WS-1'; resourceId = '' })

            $rows[0].error | Should -Be 'no ResourceID in the affinity rows'
            Should -Not -Invoke Invoke-RestMethod
        }
    }
}
