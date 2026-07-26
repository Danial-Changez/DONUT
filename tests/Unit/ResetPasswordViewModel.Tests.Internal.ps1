using module "..\..\src\Models\AdSearchResult.psm1"
using module "..\..\src\UI\ViewModels\ResetPasswordViewModel.psm1"

Describe "ResetPasswordViewModel" {
    BeforeAll {
        function New-User {
            $u = [AdSearchResult]::new()
            $u.Kind = 'User'
            $u.SamAccountName = 'sarah'
            $u.Domain = 'prod.contoso.com'
            $u.UserPrincipalName = 'sarah.test@contoso.com'
            $u.DisplayName = 'Sarah Test'
            $u.Name = 'Sarah Test'
            return $u
        }
    }

    It "defaults: empty password, change-at-logon on, not busy" {
        $vm = [ResetPasswordViewModel]::new()
        $vm.Password | Should -Be ''
        $vm.ChangeAtLogon | Should -BeTrue
        $vm.IsBusy | Should -BeFalse
    }

    It "SetTarget fills the target fields from a finder row" {
        $vm = [ResetPasswordViewModel]::new()
        $vm.SetTarget((New-User))
        $vm.TargetSam | Should -Be 'sarah'
        $vm.TargetDomain | Should -Be 'prod.contoso.com'
        $vm.TargetUpn | Should -Be 'sarah.test@contoso.com'
        $vm.DisplayName | Should -Be 'Sarah Test'
    }

    It "SetTarget falls back to Name when DisplayName is blank" {
        $u = New-User
        $u.DisplayName = ''
        $vm = [ResetPasswordViewModel]::new()
        $vm.SetTarget($u)
        $vm.DisplayName | Should -Be 'Sarah Test'
    }

    It "SetTarget re-arms fresh defaults on every open" {
        $vm = [ResetPasswordViewModel]::new()
        $vm.Password = 'left-over-secret'
        $vm.ChangeAtLogon = $false
        $vm.IsBusy = $true
        $vm.SetTarget((New-User))
        $vm.Password | Should -Be ''
        $vm.ChangeAtLogon | Should -BeTrue
        $vm.IsBusy | Should -BeFalse
    }

    It "SetTarget ignores null without clearing the current target" {
        $vm = [ResetPasswordViewModel]::new()
        $vm.SetTarget((New-User))
        $vm.SetTarget($null)
        $vm.TargetSam | Should -Be 'sarah'
    }

    It "ClearSecrets wipes the password" {
        $vm = [ResetPasswordViewModel]::new()
        $vm.Password = 'Abcde-Fghjk-23'
        $vm.ClearSecrets()
        $vm.Password | Should -Be ''
    }
}
