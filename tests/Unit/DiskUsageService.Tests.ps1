using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\DiskUsage.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DiskUsageService.psm1"
using module "..\Helpers\MockNetworkProbe.psm1"
using namespace System.Net

Describe "DiskUsageService" {
    BeforeAll {
        $script:tempDir = Join-Path $TestDrive "DiskUsage"
        $scriptsDir = Join-Path $script:tempDir 'Scripts'
        New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $scriptsDir 'RemoteWorker.ps1') -ItemType File -Force | Out-Null
        $script:reportsDir = Join-Path $script:tempDir 'Reports'
        New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:config = [AppConfig]::new(
            $script:tempDir, (Join-Path $script:tempDir 'Logs'), $script:reportsDir, @{})
        $script:service = [DiskUsageService]::new($script:config, [MockNetworkProbe]::new())
    }

    Context "PrepareDiskScan" {
        It "tags the job DiskScan and carries the default row cap" {
            $prep = $script:service.PrepareDiskScan('WSID-7')

            $prep.Arguments.HostName | Should-Be 'WSID-7'
            $prep.Arguments.JobType | Should-Be 'DiskScan'
            $prep.Arguments.Options.TopN | Should-Be 12
        }

        It "honors a configured folder-scan count" {
            $cfg = [AppConfig]::new(
                $script:tempDir, (Join-Path $script:tempDir 'Logs'), $script:reportsDir,
                @{ folderScanCount = 5 })
            $svc = [DiskUsageService]::new($cfg, [MockNetworkProbe]::new())

            $svc.PrepareDiskScan('H').Arguments.Options.TopN | Should-Be 5
        }
    }

    Context "PrepareDeleteFolders" {
        It "ships the operator-selected paths in Options, never a command line" {
            $prep = $script:service.PrepareDeleteFolders('WSID-7', @('C:\Temp\big', 'C:\Dumps'))

            $prep.Arguments.JobType | Should-Be 'DeleteFolders'
            $prep.Arguments.Options.Paths | Should-BeEquivalent @('C:\Temp\big', 'C:\Dumps')
        }
    }

    Context "DeleteReport" {
        It "removes the host's folders CSV and tolerates a missing one" {
            $path = Join-Path $script:reportsDir 'GONE-folders.csv'
            Set-Content -Path $path -Value 'x'

            # The second call proves a missing file is a no-op, not a throw.
            $script:service.DeleteReport('GONE')
            $script:service.DeleteReport('GONE')

            Test-Path $path | Should-BeFalse
        }
    }

    Context "ParseDiskUsage" {
        It "parses the worker's top-rows CSV into a typed report (volume root dropped)" {
            Set-Content -Path (Join-Path $script:reportsDir 'DUHOST-folders.csv') -Value @'
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\",5368709120,5368709120,2026-08-01,16,0,2
"C:\Games\",4294967296,4294967296,2026-08-01,16,0,0
"C:\Temp\",1048576,1048576,2026-08-01,16,0,0
'@

            $report = $script:service.ParseDiskUsage('DUHOST')

            Should-NotBeNull $report
            $report.Folders.Count | Should-Be 2
            $report.Folders[0].Path | Should-Be 'C:\Games\'
            $report.Folders[0].SizeBytes | Should-Be 4294967296
        }

        It "returns null when no report exists for the host" {
            Should-BeNull $script:service.ParseDiskUsage('NOFILE')
        }

        It "returns an empty report for a corrupt file instead of throwing" {
            Set-Content -Path (Join-Path $script:reportsDir 'BAD-folders.csv') -Value 'not a wiztree export'

            $report = $script:service.ParseDiskUsage('BAD')

            Should-NotBeNull $report
            $report.Folders.Count | Should-Be 0
        }
    }
}
