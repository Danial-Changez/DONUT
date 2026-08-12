using module "..\..\src\UI\ViewModels\PersonLensViewModel.psm1"

Describe "PersonLensViewModel software view" {

    BeforeEach {
        $script:vm = [PersonLensViewModel]::new()
    }

    It "applies software rows and clears the status" {
        $rows = @([pscustomobject]@{ Software = 'Zoom Workplace'; Collection = 'Zoom Deploy - WASH' })
        $script:vm.ApplySoftware($rows, '')
        @($script:vm.Deployments).Count | Should-Be 1
        $script:vm.Deployments[0].Software | Should-Be 'Zoom Workplace'
        $script:vm.SoftwareStatusText | Should-Be ''
    }

    It "names the empty case and carries the error case" {
        $script:vm.ApplySoftware(@(), '')
        $script:vm.SoftwareStatusText | Should-Be 'No application deployments.'
        $script:vm.ApplySoftware(@(), 'SCCM software: 404')
        $script:vm.SoftwareStatusText | Should-Be 'SCCM software: 404'
    }

    It "the toggle flips the pane and its labels both ways" {
        $script:vm.ToggleSoftwareCommand.Execute($null)
        $script:vm.IsSoftwareShown | Should-BeTrue
        $script:vm.ListLabel | Should-Be 'SOFTWARE'
        $script:vm.ToggleLabel | Should-Be 'Devices'
        $script:vm.ToggleSoftwareCommand.Execute($null)
        $script:vm.IsSoftwareShown | Should-BeFalse
        $script:vm.ListLabel | Should-Be 'DEVICES'
        $script:vm.ToggleLabel | Should-Be 'Software'
    }

    It "SetLoading resets the software view for the next pick" {
        $script:vm.ApplySoftware(@([pscustomobject]@{ Software = 'Zoom'; Collection = 'Z' }), '')
        $script:vm.ToggleSoftwareCommand.Execute($null)
        $script:vm.SetLoading('Jane Doe')
        $script:vm.IsSoftwareShown | Should-BeFalse
        @($script:vm.Deployments).Count | Should-Be 0
        $script:vm.SoftwareStatusText | Should-Be 'Looking up software…'
        $script:vm.ListLabel | Should-Be 'DEVICES'
        $script:vm.ToggleLabel | Should-Be 'Software'
    }
}
