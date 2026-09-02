# The wrapper loads WPF and Donut.Mvvm. Both guards stop a stalled lookup stranding the pane.
using module "..\..\src\UI\Presenters\FinderPresenter.psm1"
using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\PersonLens.psm1"
using module "..\..\src\Core\RunspaceManager.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# --- Test doubles -----------------------------------------------------------

# Forces the completion branch to fail after the job has already left LensJobs, the
# exact shape that used to strand the pane with no job left to retry.
class ThrowingFinderPresenter : FinderPresenter {
    ThrowingFinderPresenter([AppConfig]$c, [object]$l)
    : base($c, $null, $l, $null, $null, $null) {}

    hidden [void] WireLensDeviceCommands() { throw "device wiring blew up" }
}

# Records what WarmLens dispatches instead of touching the pool, so the warm's shape is
# assertable headless. Returns a job shaped like PoolScriptJob.Start's.
class RecordingFinderPresenter : FinderPresenter {
    [System.Collections.Generic.List[hashtable]] $Dispatched =
    [System.Collections.Generic.List[hashtable]]::new()

    RecordingFinderPresenter([AppConfig]$c, [object]$l) : base($c, $null, $l, $null, $null, $null) {}

    hidden [hashtable] StartPoolScript([string]$scriptPath, [hashtable]$parameters) {
        $this.Dispatched.Add($parameters)
        return @{ Ps = $null; Handle = $null; StartedAt = [datetime]::UtcNow }
    }
}

Describe "FinderPresenter Lens poll" {

    BeforeAll {
        # Must live in BeforeAll: a file-scope helper is discovery-only and out of scope in It.
        # A never-invoked PowerShell disposes synchronously, so DisposeJob needs no reap timer.
        function New-LensJob {
            param([int]$Token, [int]$AgeSeconds, [bool]$Completed = $false, [string]$Who = 'Jane Doe')
            return @{
                Ps        = [System.Management.Automation.PowerShell]::Create()
                Handle    = [PSCustomObject]@{ IsCompleted = $Completed }
                Token     = $Token
                Key       = 'jane@corp.example'
                InfoSeen  = 0
                StartedAt = [datetime]::UtcNow.AddSeconds(-$AgeSeconds)
                Who       = $Who
            }
        }

        # A finished search leg carrying whatever the worker put on its Information stream.
        # Omit -Payload for the leg that emitted nothing at all.
        function New-TimedSearchJob {
            param([datetime]$StartedAt, [string]$Payload, [string]$Tag = 'AdTiming')
            $ps = [System.Management.Automation.PowerShell]::Create()
            if ($Payload) {
                $rec = [System.Management.Automation.InformationRecord]::new($Payload, 'worker')
                $rec.Tags.Add($Tag)
                $ps.Streams.Information.Add($rec)
            }
            return @{ Ps = $ps; StartedAt = $StartedAt; Domain = 'd1'; Prefix = 'dan' }
        }
    }

    BeforeEach {
        $script:logger = [CapturingLogService]::new()
        $script:config = [AppConfig]::new("C:\Src", "C:\Logs", "C:\Reports", @{})
        $script:presenter = [FinderPresenter]::new(
            $script:config, $null, $script:logger, $null, $null, $null)
    }

    Context "deadline backstop" {
        It "retires a lookup that outlived the deadline and shows a reason" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            $p.LensJobs.Add((New-LensJob -Token 1 -AgeSeconds 120))

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 0
            $p.LensVm.IsLoading | Should -BeFalse
            $p.LensVm.HasError | Should -BeTrue
            $p.LensVm.StatusText | Should -Not -BeNullOrEmpty
            $script:logger.HasLevel("WARN") | Should -BeTrue
        }

        It "keeps the picked name on screen when it gives up" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            $job = New-LensJob -Token 1 `
                               -AgeSeconds 120 `
                               -Who 'Jane Doe'
            $p.LensJobs.Add($job)

            $p.PollLens()

            # Apply() blanks DisplayName from an error lens unless the caller carries it.
            $p.LensVm.DisplayName | Should -BeExactly 'Jane Doe'
        }

        It "leaves a lookup that is still inside the deadline alone" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            $p.LensJobs.Add((New-LensJob -Token 1 -AgeSeconds 5))

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 1
            $p.LensVm.IsLoading | Should -BeTrue
            $p.LensVm.HasError | Should -BeFalse
        }

        It "retires a superseded expired lookup without touching the pane" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Newer Person')
            $p.LensToken = 2                     # A newer pick already owns the pane.
            $p.LensJobs.Add((New-LensJob -Token 1 -AgeSeconds 120))

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 0
            $p.LensVm.IsLoading | Should -BeTrue -Because "the newer pick is still loading"
            $p.LensVm.HasError | Should -BeFalse
        }

        It "honours a shortened deadline" {
            $p = $script:presenter
            $p.LensDeadline = [timespan]::FromSeconds(2)
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            $p.LensJobs.Add((New-LensJob -Token 1 -AgeSeconds 5))

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 0
            $p.LensVm.HasError | Should -BeTrue
        }
    }

    Context "search timing breadcrumb" {
        It "splits a leg into queue / search / rows / notice" {
            $dispatch = [datetime]::UtcNow.AddMilliseconds(-500)
            $begun = $dispatch.AddMilliseconds(20)
            $ended = $begun.AddMilliseconds(210)
            $job = New-TimedSearchJob -StartedAt $dispatch `
                                      -Payload "$($begun.Ticks) 200 $($ended.Ticks)"

            $text = $script:presenter.DescribeSearchTiming($job)

            $text | Should -Match 'queue 20\b'
            $text | Should -Match 'search 200\b'
            $text | Should -Match 'rows 10\b'   # Worker total minus the search itself.
            $text | Should -Match 'notice \d+'
        }

        # A superseded or thrown leg emits no record, and that must not throw in the poll loop.
        It "degrades to nothing when the worker emitted no record" {
            $job = New-TimedSearchJob -StartedAt ([datetime]::UtcNow)
            $script:presenter.DescribeSearchTiming($job) | Should -BeExactly ''
        }

        It "degrades to nothing when another record carries a different tag" {
            $job = New-TimedSearchJob -StartedAt ([datetime]::UtcNow) `
                                      -Payload 'partial bundle' `
                                      -Tag 'LensPartial'
            $script:presenter.DescribeSearchTiming($job) | Should -BeExactly ''
        }

        It "degrades to nothing when the record is not three fields" {
            $job = New-TimedSearchJob -StartedAt ([datetime]::UtcNow) -Payload '123 456'
            $script:presenter.DescribeSearchTiming($job) | Should -BeExactly ''
        }
    }

    Context "lens warm" {
        It "starts the agent once and leaves the rest of the pool free" {
            $p = [RecordingFinderPresenter]::new($script:config, $script:logger)

            $p.WarmLens()

            $blocking = @($p.Dispatched | Where-Object { $_.WarmOnly })
            $blocking.Count | Should -Be 1 -Because "EnsureAgent holds a runspace for its cold start"
            $parseOnly = @($p.Dispatched | Where-Object { $_.ParseOnly })
            $parseOnly.Count | Should -Be ([RunspaceManager]::InteractiveSize - 1)
            # One blocking job per runspace is what left the finder's fan-out nowhere to go.
            $p.Dispatched.Count | Should -Be ([RunspaceManager]::InteractiveSize)
        }
    }

    # A stopped pipeline used to apply and cache a blank lens: both reaps must read it as a failure.
    Context "interrupted lookup" {

        It "shows the retry hint instead of a blank pane when the pipeline dies" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            # The fake handle makes EndInvoke throw, the shape a stopped pipeline leaves.
            $p.LensJobs.Add((New-LensJob -Token 1 -AgeSeconds 1 -Completed $true))

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 0
            $p.LensVm.IsLoading | Should -BeFalse
            $p.LensVm.HasError | Should -BeTrue
            $p.LensVm.StatusText | Should -Match 'interrupted'
            $p.LensVm.DisplayName | Should -BeExactly 'Jane Doe'
            $p.LensCache.Count | Should -Be 0 -Because "a failed lookup must not poison the cache"
        }

        It "tells the software view its lookup died instead of saying none exist" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.SoftwareKey = 'jane@corp.example'
            $p.SoftwareJob = @{
                Ps        = [System.Management.Automation.PowerShell]::Create()
                Handle    = [PSCustomObject]@{ IsCompleted = $true }
                Key       = 'jane@corp.example'
                StartedAt = [datetime]::UtcNow
            }

            $p.PollLens()

            $p.SoftwareJob | Should -Be $null
            $p.LensVm.Deployments.Count | Should -Be 0
            $p.LensVm.SoftwareStatusText | Should -Match 'interrupted'
        }

        It "leaves the pane alone when a superseded software lookup dies" {
            $p = $script:presenter
            $p.LensVm.SetLoading('Jane Doe')
            $p.SoftwareKey = 'newer@corp.example'
            $p.SoftwareJob = @{
                Ps        = [System.Management.Automation.PowerShell]::Create()
                Handle    = [PSCustomObject]@{ IsCompleted = $true }
                Key       = 'older@corp.example'
                StartedAt = [datetime]::UtcNow
            }

            $p.PollLens()

            $p.LensVm.SoftwareStatusText | Should -BeExactly 'Looking up software…'
        }
    }

    Context "completion guard" {
        It "surfaces a failure instead of stranding the pane when applying throws" {
            $p = [ThrowingFinderPresenter]::new($script:config, $script:logger)
            $p.LensVm.SetLoading('Jane Doe')
            $p.LensToken = 1
            $job = New-LensJob -Token 1 `
                               -AgeSeconds 1 `
                               -Completed $true
            $p.LensJobs.Add($job)

            $p.PollLens()

            $p.LensJobs.Count | Should -Be 0
            $p.LensVm.IsLoading | Should -BeFalse -Because "the job is gone, so nothing retries"
            $p.LensVm.HasError | Should -BeTrue
            $p.LensVm.DisplayName | Should -BeExactly 'Jane Doe'
        }
    }
}
