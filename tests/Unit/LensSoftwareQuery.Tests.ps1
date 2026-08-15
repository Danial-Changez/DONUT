Describe "Lens software query" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] binds live inside function bodies.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:Software = $script:SoftwareScript

        function New-Collection { param($Rows) return [pscustomobject]@{ value = @($Rows) } }
        function New-SccmUser {
            param([string]$Unique, [int]$Id)
            return [pscustomobject]@{ UniqueUserName = $Unique; ResourceID = $Id }
        }
        function New-Membership { param([string]$Id) return [pscustomobject]@{ CollectionID = $Id } }
        function New-Deployment {
            param([string]$Software, [string]$Collection, [string]$Id,
                [int]$Feature = 1, [int]$Config = 1, [string]$Program = '')
            return [pscustomobject]@{ SoftwareName = $Software; CollectionName = $Collection
                CollectionID = $Id; FeatureType = $Feature; DesiredConfigType = $Config
                ProgramName = $Program
            }
        }
    }

    Context "the full walk" {

        It "keeps the user's application installs and package deployments, nothing else" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') {
                    return New-Collection @((New-SccmUser 'CORP\jdoe' 100), (New-SccmUser 'CORP\ajdoe' 999))
                }
                if ($Uri -match 'SMS_FullCollectionMembership') {
                    return New-Collection @((New-Membership 'WSH001'), (New-Membership 'WSH002'))
                }
                return New-Collection @(
                    (New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'),
                    (New-Deployment '7-Zip' 'Legacy Package Push' 'WSH001' -Feature 2 -Program 'Install - silent'),
                    (New-Deployment 'Acrobat' 'Acrobat Removal - WASH' 'WSH002' -Config 2),
                    (New-Deployment 'Chrome' 'Chrome Deploy - WASH' 'WSH999'),
                    (New-Deployment 'Baseline' 'Compliance - WASH' 'WSH001' -Feature 6)
                )
            }

            $rows = @(& $script:Software 'sccm.corp.com' 'jdoe')

            # The uninstall app, the non-member collection and the baseline all drop.
            @($rows).Count | Should-Be 2
            $rows[0].software | Should-Be '7-Zip'
            $rows[0].program | Should-Be 'Install - silent'
            $rows[1].software | Should-Be 'Zoom Workplace'
            $rows[1].program | Should-Be ''
            # One user query, one membership query, one summary fetch.
            Should -Invoke Invoke-RestMethod -Times 3 -Exactly
            # The near-miss SAM tail never earns a membership query.
            Should -Not -Invoke Invoke-RestMethod -ParameterFilter { $Uri -match '999' }
        }

        It "sorts by software and collapses duplicate pairs, though a program keeps its own row" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-Collection @((New-SccmUser 'CORP\jdoe' 100)) }
                if ($Uri -match 'SMS_FullCollectionMembership') { return New-Collection @((New-Membership 'WSH001')) }
                return New-Collection @(
                    (New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'),
                    (New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'),
                    (New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001' -Feature 2 -Program 'Repair'),
                    (New-Deployment 'Adobe Reader' 'Reader Deploy - WASH' 'WSH001')
                )
            }

            $rows = @(& $script:Software 'sccm.corp.com' 'jdoe')

            @($rows).Count | Should-Be 3
            $rows[0].software | Should-Be 'Adobe Reader'
            @($rows | Where-Object { $_.program -eq 'Repair' }).Count | Should-Be 1
        }

        It "unions memberships when two domains share the SAM tail" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') {
                    return New-Collection @((New-SccmUser 'CORP\jdoe' 100), (New-SccmUser 'DEV\jdoe' 200))
                }
                if ($Uri -match 'eq%20100') { return New-Collection @((New-Membership 'WSH001')) }
                if ($Uri -match 'eq%20200') { return New-Collection @((New-Membership 'WSH002')) }
                return New-Collection @(
                    (New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'),
                    (New-Deployment 'Acrobat' 'Acrobat Deploy - WASH' 'WSH002')
                )
            }

            $rows = @(& $script:Software 'sccm.corp.com' 'jdoe')

            @($rows).Count | Should-Be 2
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
                $Uri -match 'SMS_FullCollectionMembership' }
        }
    }

    Context "empty hops stop the walk early" {

        It "returns nothing without an SCCM user record, asking nothing further" {
            Mock Invoke-RestMethod { return New-Collection @((New-SccmUser 'CORP\ajdoe' 999)) }

            $rows = @(& $script:Software 'sccm.corp.com' 'jdoe')

            @($rows).Count | Should-Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly
        }

        It "returns nothing when the user is in no collections, skipping the summary fetch" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-Collection @((New-SccmUser 'CORP\jdoe' 100)) }
                return New-Collection @()
            }

            $rows = @(& $script:Software 'sccm.corp.com' 'jdoe')

            @($rows).Count | Should-Be 0
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly
        }
    }

    Context "Resolve-UserSoftware wraps the walk in a bundle" {

        It "catches a hop failure into one error string" {
            Mock Invoke-RestMethod { throw 'Response status code does not indicate success: 404 (Not Found).' }

            $bundle = Resolve-UserSoftware -identity 'jdoe' -sam 'jdoe' -server 'sccm.corp.com' |
                ConvertFrom-Json

            @($bundle.deployments).Count | Should-Be 0
            ($bundle.error -match 'SCCM software') | Should-BeTrue
            ($bundle.error -match '404') | Should-BeTrue
        }

        It "answers a blank server without asking anything" {
            Mock Invoke-RestMethod { throw 'should not be reached' }

            $bundle = Resolve-UserSoftware -identity 'jdoe' -sam 'jdoe' -server '' | ConvertFrom-Json

            $bundle.error | Should-Be 'no AdminService host configured'
            Should -Not -Invoke Invoke-RestMethod
        }

        It "derives the SAM from a domain-qualified identity without touching AD" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-Collection @((New-SccmUser 'CORP\jdoe' 100)) }
                if ($Uri -match 'SMS_FullCollectionMembership') { return New-Collection @((New-Membership 'WSH001')) }
                return New-Collection @((New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'))
            }
            function Find-Gc { param([string]$Filter) throw 'AD must not be asked for a derivable SAM' }

            $bundle = Resolve-UserSoftware -identity 'CORP\jdoe' -sam '' -server 'sccm.corp.com' |
                ConvertFrom-Json

            @($bundle.deployments).Count | Should-Be 1
            $bundle.deployments[0].software | Should-Be 'Zoom Workplace'
        }

        It "binds the picked DN for the SAM ahead of any GC search, as the person read does" {
            Mock Invoke-RestMethod {
                if ($Uri -match 'SMS_R_User') { return New-Collection @((New-SccmUser 'CORP\jdoe' 100)) }
                if ($Uri -match 'SMS_FullCollectionMembership') { return New-Collection @((New-Membership 'WSH001')) }
                return New-Collection @((New-Deployment 'Zoom Workplace' 'Zoom Deploy - WASH' 'WSH001'))
            }
            function Get-DnSam { param([string]$dn) if ($dn -eq 'CN=J Doe,DC=corp') { 'jdoe' } else { '' } }
            function Find-Gc { param([string]$Filter) throw 'the DN in hand must win over a GC guess' }

            $bundle = Resolve-UserSoftware -identity 'J Doe' -sam '' -server 'sccm.corp.com' -dn 'CN=J Doe,DC=corp' |
                ConvertFrom-Json

            @($bundle.deployments).Count | Should-Be 1
            $bundle.deployments[0].software | Should-Be 'Zoom Workplace'
        }

        It "still falls back to the GC when the DN cannot bind" {
            Mock Invoke-RestMethod { throw 'should not be reached' }
            function Get-DnSam { param([string]$dn) '' }
            function Find-Gc { param([string]$Filter) throw 'GC unreachable' }

            $bundle = Resolve-UserSoftware -identity 'J Doe' -sam '' -server 'sccm.corp.com' -dn 'CN=stale,DC=corp' |
                ConvertFrom-Json

            @($bundle.deployments).Count | Should-Be 0
            ($bundle.error -match 'GC unreachable') | Should-BeTrue
        }
    }
}
