using module "..\..\src\UI\Presenters\AsyncJobPresenter.psm1"
using module "..\..\src\Core\AsyncJob.psm1"

# Records hook invocations so the shared PumpJobs lifecycle can be verified without
# WPF or a live runspace.
class RecordingPresenter : AsyncJobPresenter {
    [System.Collections.Generic.List[string]] $Polled
    [System.Collections.Generic.List[string]] $Completed
    [int] $AfterPumpCount = 0

    # Appended the first time AppendTrigger completes, modelling Home's scan to apply hop.
    [AsyncJob] $JobToAppendOnComplete = $null
    [string] $AppendTrigger = $null

    [bool] $Modal = $false
    [bool] IsModalOpen() { return $this.Modal }

    RecordingPresenter() : base() {
        $this.Polled = [System.Collections.Generic.List[string]]::new()
        $this.Completed = [System.Collections.Generic.List[string]]::new()
    }

    [void] OnJobPolled([AsyncJob]$job) {
        $this.Polled.Add($job.HostName)
    }

    [void] OnJobCompleted([AsyncJob]$job) {
        $this.Completed.Add($job.HostName)
        if ($this.JobToAppendOnComplete -and $job.HostName -eq $this.AppendTrigger) {
            $this.ActiveJobs.Add($this.JobToAppendOnComplete)
            $this.JobToAppendOnComplete = $null
        }
    }

    [void] AfterPump() {
        $this.AfterPumpCount++
    }
}

Describe "AsyncJobPresenter" {

    BeforeAll {
        function New-TerminalJob {
            param([string]$hostName, [string]$status)
            # With no Start(), Poll() no-ops off Status and Cleanup() sees a null PowerShell.
            $job = [AsyncJob]::new($hostName, 'Scan')
            $job.Status = $status
            return $job
        }
    }

    BeforeEach {
        $script:p = [RecordingPresenter]::new()
    }

    Context "PumpJobs" {
        It "Initializes ActiveJobs via the base constructor" {
            $null -ne $script:p.ActiveJobs | Should -Be $true
            $script:p.ActiveJobs.Count | Should -Be 0
        }

        It "No-ops when there are no active jobs" {
            $script:p.PumpJobs()
            $script:p.AfterPumpCount | Should -Be 0
            $script:p.Polled.Count | Should -Be 0
        }

        It "Polls every job and removes terminal ones, keeping running ones" {
            $script:p.ActiveJobs.Add((New-TerminalJob "DONE" "Completed"))
            $script:p.ActiveJobs.Add((New-TerminalJob "FAIL" "Failed"))
            $running = [AsyncJob]::new("RUN", 'Scan'); $running.Status = 'Running'
            $script:p.ActiveJobs.Add($running)

            $script:p.PumpJobs()

            ($script:p.Polled | Sort-Object) | Should -Be @("DONE", "FAIL", "RUN")
            ($script:p.Completed | Sort-Object) | Should -Be @("DONE", "FAIL")
            $script:p.ActiveJobs.Count | Should -Be 1
            $script:p.ActiveJobs[0].HostName | Should -Be "RUN"
        }

        It "Calls AfterPump once per tick that processed jobs" {
            $script:p.ActiveJobs.Add((New-TerminalJob "A" "Completed"))
            $script:p.ActiveJobs.Add((New-TerminalJob "B" "Completed"))

            $script:p.PumpJobs()

            $script:p.AfterPumpCount | Should -Be 1
        }

        It "Keeps a job appended during completion (scan -> apply transition)" {
            $apply = [AsyncJob]::new("HOST", 'Scan'); $apply.Status = 'Running'
            $script:p.JobToAppendOnComplete = $apply
            $script:p.AppendTrigger = "HOST"

            $scan = New-TerminalJob "HOST" "Completed"
            $script:p.ActiveJobs.Add($scan)

            $script:p.PumpJobs()

            $script:p.Completed | Should -Be @("HOST")
            $script:p.ActiveJobs.Count | Should -Be 1
            $script:p.ActiveJobs[0] | Should -Be $apply
        }

        It "Defers completion + AfterPump while a modal is open, but still polls" {
            $script:p.Modal = $true
            $script:p.ActiveJobs.Add((New-TerminalJob "DONE" "Completed"))

            $script:p.PumpJobs()

            $script:p.Polled | Should -Be @("DONE")    # Still polled, so the UI keeps updating.
            $script:p.Completed.Count | Should -Be 0   # Completion may open a dialog, so deferred.
            $script:p.AfterPumpCount | Should -Be 0    # AfterPump can open a dialog too.
            $script:p.ActiveJobs.Count | Should -Be 1  # Kept for a later, non-modal tick.

            $script:p.Modal = $false
            $script:p.PumpJobs()
            $script:p.Completed | Should -Be @("DONE")
            $script:p.ActiveJobs.Count | Should -Be 0
        }

        It "Skips null entries without throwing" {
            $script:p.ActiveJobs.Add((New-TerminalJob "A" "Completed"))
            $script:p.ActiveJobs.Add($null)

            { $script:p.PumpJobs() } | Should -Not -Throw
            $script:p.Completed | Should -Be @("A")
        }
    }
}
