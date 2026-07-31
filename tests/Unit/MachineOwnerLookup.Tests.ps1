Describe "Machine owner lookup" {

    BeforeAll {
        # Dot-sourcing is safe off Windows: the [ADSI] binds live inside function bodies,
        # never at parse. Find-Gc is redefined per test to stand in for the directory.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:Owners = $script:OwnerScript

        function New-Affinity { param($Rows) return [pscustomobject]@{ value = @($Rows) } }
    }

    Context "the whole list travels in one call" {

        It "returns one row per machine, in order, and never queries AD twice for one" {
            Mock Invoke-RestMethod {
                $name = if ($Uri -match "ResourceName%20eq%20'([^']+)'") { $Matches[1] } else { '' }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = "CORP\u$name"; ResourceName = $name })
            }
            function Find-Gc { param([string]$Filter) return $null }

            $json = Resolve-MachineOwnerBatch -wsids @('WS-1', 'WS-2', 'WS-3') -server 'sccm.corp.com'
            $bundle = $json | ConvertFrom-Json

            @($bundle.owners).Count | Should -Be 3
            $bundle.owners[0].name | Should -Be 'WS-1'
            $bundle.owners[2].name | Should -Be 'WS-3'
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly
        }

        It "falls back to the SAM when the directory read finds nothing" {
            # A SAM still tells two machines apart, which is the whole job of this field.
            Mock Invoke-RestMethod {
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }
            function Find-Gc { param([string]$Filter) return $null }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com') | ConvertFrom-Json

            $bundle.owners[0].sam | Should -Be 'jdoe'
            $bundle.owners[0].owner | Should -Be 'jdoe'
        }

        It "names the reason per machine without failing the rest of the batch" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'WS-BAD') { throw 'Response status code does not indicate success: 500.' }
                return New-Affinity @()
            }
            function Find-Gc { param([string]$Filter) return $null }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-BAD', 'WS-NONE') -server 'sccm.corp.com') | ConvertFrom-Json

            @($bundle.owners).Count | Should -Be 2
            $bundle.owners[0].error | Should -Match 'SCCM affinity'
            $bundle.owners[1].error | Should -Match 'no primary user recorded'
            $bundle.owners[1].owner | Should -BeNullOrEmpty
        }

        It "says so once when no AdminService host is configured" {
            Mock Invoke-RestMethod { throw 'should not be reached' }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1') -server '') | ConvertFrom-Json

            $bundle.error | Should -Match 'no AdminService host'
            Should -Not -Invoke Invoke-RestMethod
        }

        It "skips blank names rather than querying for them" {
            Mock Invoke-RestMethod {
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }
            function Find-Gc { param([string]$Filter) return $null }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1', '', $null) -server 'sccm.corp.com') | ConvertFrom-Json

            @($bundle.owners).Count | Should -Be 1
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }
    }
}
