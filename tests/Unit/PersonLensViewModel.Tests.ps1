using module "..\..\src\UI\ViewModels\PersonLensViewModel.psm1"
using module "..\..\src\Models\PersonLens.psm1"

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

Describe "PersonLensViewModel partial resilience" {

    BeforeEach {
        $script:vm = [PersonLensViewModel]::new()
    }

    It "keeps the partial paint under the banner when the result is error-only" {
        $script:vm.SetLoading('Jane Doe')
        $partial = [PersonLens]::FromJson('{"sam":"jdoe","displayName":"Jane Doe","devices":[{"name":"WS1"}]}')
        $script:vm.ApplyPartial($partial)
        $script:vm.Apply([PersonLens]::FromError('Lens lookup failed: locked'))
        $script:vm.Sam | Should-Be 'jdoe'
        @($script:vm.Devices).Count | Should-Be 1
        $script:vm.HasError | Should-BeTrue
        $script:vm.StatusText | Should-Be 'Lens lookup failed: locked'
        $script:vm.IsLoading | Should-BeFalse
    }

    It "SetLoading clears the previous person's fields before a new pick" {
        $script:vm.SetLoading('Jane Doe')
        $script:vm.ApplyPartial([PersonLens]::FromJson(
                '{"sam":"jdoe","email":"jdoe@example.com","manager":"M","office":"O"}'))
        $script:vm.SetLoading('John Roe')
        $script:vm.Sam | Should-Be ''
        $script:vm.Email | Should-Be ''
        $script:vm.Manager | Should-Be ''
        $script:vm.Office | Should-Be ''
        $script:vm.DisplayName | Should-Be 'John Roe'
    }
}
