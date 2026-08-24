using module "..\..\src\UI\ViewModels\HostViewModel.psm1"

Describe "HostViewModel reachability" {

    It "shows offline on the chip alone, with the subtitle and the title left bare" {
        $vm = [HostViewModel]::new('CAP-9F3KQ2')
        $vm.SetReachability('Offline')
        $vm.ChipVisible | Should -BeTrue
        $vm.ChipText | Should -Be 'Offline'
        $vm.Subtitle | Should -Be 'Never run'
        $vm.HostName | Should -Be 'CAP-9F3KQ2'
        ($vm | Get-Member -Name 'DetailTitle') | Should -BeNullOrEmpty
    }

    It "restores the idle rendering when the host is reachable again" {
        $vm = [HostViewModel]::new('CAP-9F3KQ2')
        $vm.SetReachability('Offline')
        $vm.SetReachability('Online')
        $vm.ChipVisible | Should -BeFalse
        $vm.Subtitle | Should -Be 'Never run'
    }
}
