Describe "Machine owner lookup" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] binds live inside function bodies.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:Owners = $script:OwnerScript

        function New-Affinity { param($Rows) return [pscustomobject]@{ value = @($Rows) } }
        function New-SccmUser { param([string]$Full) return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ FullUserName = $Full; UniqueUserName = 'CORP\whoever' }) }
        }
    }

    BeforeEach {
        # The memo lives for a batch job's runspace in the agent, so tests must not share it.
        $script:OwnerNameCache = @{}
        # Default directory stub finds nothing, tests that need more redefine it inline.
        function Find-Gc { param([string]$Filter) return $null }
    }

    Context "the whole list travels in one call" {

        It "returns one row per machine, in order, naming each distinct owner exactly once" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-SccmUser 'Jane Doe' }
                # The quotes arrive percent-encoded (%27), so match the name bare.
                $name = if ("$Uri" -match 'WS-\d') { $Matches[0] } else { '' }
                # WS-1 and WS-2 share an owner, so the memo must collapse their name reads.
                $sam = if ($name -eq 'WS-3') { 'usolo' } else { 'ushared' }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = "CORP\$sam"; ResourceName = $name })
            }
            function Find-Gc { param([string]$Filter) throw 'AD must not be asked when SCCM answers' }

            $json = Resolve-MachineOwnerBatch -wsids @('WS-1', 'WS-2', 'WS-3') -server 'sccm.corp.com'
            $bundle = $json | ConvertFrom-Json

            @($bundle.owners).Count | Should -Be 3
            $bundle.owners[0].name | Should -Be 'WS-1'
            $bundle.owners[2].name | Should -Be 'WS-3'
            $bundle.owners[0].owner | Should -Be 'Jane Doe'
            # 3 affinity queries + 2 name queries (two machines share an owner) = 5.
            Should -Invoke Invoke-RestMethod -Times 5 -Exactly
        }

        It "names the owner from SCCM without ever touching the directory" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-SccmUser 'Danial Changez' }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\asmith'; ResourceName = 'WS-1' })
            }
            function Find-Gc { param([string]$Filter) throw 'AD must not be asked when SCCM answers' }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com') | ConvertFrom-Json

            $bundle.owners[0].owner | Should -Be 'Danial Changez'
            $bundle.owners[0].sam | Should -Be 'asmith'
        }

        It "falls back to the directory when SCCM has no name for the account" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return [pscustomobject]@{ value = @() } }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }
            # The stub hit proves the order: SCCM answered empty, so the directory is asked next.
            # Its [ADSI] bind fails off Windows, so the catch falls back to the SAM.
            function Find-Gc { param([string]$Filter)
                return [pscustomobject]@{ Properties = @{ distinguishedname = @('CN=x') } }
            }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com') | ConvertFrom-Json

            $bundle.owners[0].sam | Should -Be 'jdoe'
            $bundle.owners[0].owner | Should -Be 'jdoe'
            $bundle.owners[0].error | Should -Match 'AD user'
        }

        It "falls back to the SAM when neither SCCM nor the directory can name the account" {
            # A SAM still tells two machines apart, which is the whole job of this field.
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return [pscustomobject]@{ value = @() } }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com') | ConvertFrom-Json

            $bundle.owners[0].sam | Should -Be 'jdoe'
            $bundle.owners[0].owner | Should -Be 'jdoe'
        }

        It "remembers a resolved name across batches, but never memoizes a miss" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-SccmUser 'Jane Doe' }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }

            [void](Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com')
            [void](Resolve-MachineOwnerBatch -wsids @('WS-1') -server 'sccm.corp.com')

            # 2 affinity (one per batch) + 1 name: the second batch hits the memo.
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly
            $script:OwnerNameCache['CORP\jdoe'] | Should -Be 'Jane Doe'
        }

        It "names the reason per machine without failing the rest of the batch" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'WS-BAD') { throw 'Response status code does not indicate success: 500.' }
                return New-Affinity @()
            }

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
                if ($Uri -match 'SMS_R_User') { return New-SccmUser 'Jane Doe' }
                return New-Affinity @([pscustomobject]@{ UniqueUserName = 'CORP\jdoe'; ResourceName = 'WS-1' })
            }

            $bundle = (Resolve-MachineOwnerBatch -wsids @('WS-1', '', $null) -server 'sccm.corp.com') | ConvertFrom-Json

            @($bundle.owners).Count | Should -Be 1
            # 1 affinity + 1 name, the blanks never reach either query.
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }
}
