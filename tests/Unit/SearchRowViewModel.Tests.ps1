using module "..\..\src\UI\ViewModels\SearchRowViewModel.psm1"

Describe "SearchRowViewModel" {
    It "maps a computer hit: name, 'domain - computer' sub, pickable" {
        $vm = [SearchRowViewModel]::FromResult([pscustomobject]@{
            Kind = 'Computer'; Name = 'WS-5330'; Domain = 'prod.contoso.com'
        })
        $vm.Primary    | Should -Be 'WS-5330'
        $vm.Secondary  | Should -Be 'prod.contoso.com  -  computer'
        $vm.IsComputer | Should -BeTrue
        $vm.CanUnlock  | Should -BeFalse
        $vm.IsHeader   | Should -BeFalse
    }

    It "maps a user hit: UPN primary, 'display - domain' sub, no unlock when not locked" {
        $vm = [SearchRowViewModel]::FromResult([pscustomobject]@{
            Kind = 'User'; UserPrincipalName = 'bob@contoso.com'; SamAccountName = 'bob'
            DisplayName = 'Bob B'; Domain = 'prod.contoso.com'; LockedOut = $false
        })
        $vm.Primary   | Should -Be 'bob@contoso.com'
        $vm.Secondary | Should -Be 'Bob B  -  prod.contoso.com'
        $vm.CanUnlock | Should -BeFalse
        $vm.IsComputer | Should -BeFalse
    }

    It "falls back to SamAccountName and appends the locked suffix for a locked user" {
        $vm = [SearchRowViewModel]::FromResult([pscustomobject]@{
            Kind = 'User'; UserPrincipalName = ''; SamAccountName = 'jdoe'
            DisplayName = ''; Domain = 'forest-c.local'; LockedOut = $true
        })
        $vm.Primary   | Should -Be 'jdoe  (locked)'   # ASCII, never an emoji (coding style)
        $vm.Secondary | Should -Be 'forest-c.local'   # blank display name dropped from the join
        $vm.CanUnlock | Should -BeTrue
    }

    It "builds section headers" {
        $h = [SearchRowViewModel]::Header('COMPUTERS')
        $h.IsHeader   | Should -BeTrue
        $h.HeaderText | Should -Be 'COMPUTERS'
        $h.CanUnlock  | Should -BeFalse
        $h.IsComputer | Should -BeFalse
    }
}
