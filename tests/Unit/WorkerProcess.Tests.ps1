using module "..\..\src\Core\WorkerProcess.psm1"

<#
    WorkerProcess owns the child-process protocol: Prepare serializes args + reserves
    the result file; Interpret turns the launcher's return into a pass/fail verdict.
    Both are pure and testable without spawning a process.
#>
Describe "WorkerProcess" {

    Context "Prepare" {
        It "serializes args to a temp file and returns the launch handle" {
            $prep = [WorkerProcess]::Prepare('C:\worker.ps1', @{ HostName = 'PC1'; JobType = 'Scan' }, '')
            try {
                Test-Path $prep.ArgsFile | Should -BeTrue
                $prep.ScriptPath | Should -Be 'C:\worker.ps1'
                $prep.PwshPath | Should -Not -BeNullOrEmpty
                $prep.Launcher | Should -BeOfType ([scriptblock])
                $a = Get-Content -LiteralPath $prep.ArgsFile -Raw | ConvertFrom-Json -AsHashtable
                $a.HostName | Should -Be 'PC1'
                $a.JobType | Should -Be 'Scan'
            }
            finally {
                Remove-Item $prep.ArgsFile, $prep.ResultFile -Force -ErrorAction SilentlyContinue
            }
        }

        It "folds a temp config path into the args as ConfigPath" {
            $prep = [WorkerProcess]::Prepare('w.ps1', @{ HostName = 'PC2' }, 'C:\temp\cfg.json')
            try {
                $a = Get-Content -LiteralPath $prep.ArgsFile -Raw | ConvertFrom-Json -AsHashtable
                $a.ConfigPath | Should -Be 'C:\temp\cfg.json'
            }
            finally {
                Remove-Item $prep.ArgsFile, $prep.ResultFile -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Context "Interpret" {
        It "reads exit 0 as success and passes the result through" {
            $v = [WorkerProcess]::Interpret([pscustomobject]@{
                    Result = @{ Ip = '10.0.0.1' }; ExitCode = 0; StdErr = ''; StdOut = '' })
            $v.Succeeded | Should -BeTrue
            $v.Result.Ip | Should -Be '10.0.0.1'
            $v.FailureMessage | Should -BeNullOrEmpty
        }

        It "reads a non-zero exit as failure with the clean stderr as the message" {
            $v = [WorkerProcess]::Interpret([pscustomobject]@{
                    Result = $null; ExitCode = 1; StdErr = "Worker failed: host offline`n"; StdOut = '' })
            $v.Succeeded | Should -BeFalse
            $v.ExitCode | Should -Be 1
            $v.FailureMessage | Should -Be 'Worker failed: host offline'
        }

        It "degrades gracefully when the launcher returned nothing" {
            $v = [WorkerProcess]::Interpret($null)
            $v.Succeeded | Should -BeFalse
            $v.FailureMessage | Should -Not -BeNullOrEmpty
        }
    }
}
