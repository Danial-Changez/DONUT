using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\DiskUsage.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\DiskUsageService.psm1"
using namespace System.Net

# Same fake probe as InventoryService.Tests: connectivity without real network.
class MockNetworkProbe : NetworkProbe {
    MockNetworkProbe() {}
    [bool] IsOnline([string]$hostName) { return $true }
    [bool] IsRpcAvailable([string]$hostName) { return $true }
    [IPAddress] ResolveHost([string]$hostName) { return [IPAddress]::Parse('127.0.0.1') }
}

Describe "DiskUsageService" {
    BeforeAll {
        $script:tempDir = Join-Path $env:TEMP "DonutTests_DiskUsage_$(Get-Random)"
        $scriptsDir = Join-Path $script:tempDir 'Scripts'
        New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null
        New-Item -Path (Join-Path $scriptsDir 'RemoteWorker.ps1') -ItemType File -Force | Out-Null
        $script:reportsDir = Join-Path $script:tempDir 'Reports'
        New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null

        $script:config = [AppConfig]::new(
            $script:tempDir, (Join-Path $script:tempDir 'Logs'), $script:reportsDir, @{})
        $script:service = [DiskUsageService]::new($script:config, [MockNetworkProbe]::new())
    }

    AfterAll {
        Remove-Item -Path $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
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

    Context "ParseDiskUsage" {
        It "parses the worker's top-N JSON into a typed report" {
            $json = @{
                scannedAt = '2026-08-01T12:00:00Z'
                folders   = @(
                    @{ path = 'C:\Games'; sizeBytes = 4294967296 },
                    @{ path = 'C:\Temp'; sizeBytes = 1048576 })
            } | ConvertTo-Json -Depth 4
            Set-Content -Path (Join-Path $script:reportsDir 'DUHOST-folders.json') -Value $json

            $report = $script:service.ParseDiskUsage('DUHOST')

            Should-NotBeNull $report
            $report.ScannedAt | Should-Be '2026-08-01T12:00:00.0000000Z'
            $report.Folders.Count | Should-Be 2
            $report.Folders[0].Path | Should-Be 'C:\Games'
            $report.Folders[0].SizeBytes | Should-Be 4294967296
        }

        It "returns null when no report exists for the host" {
            Should-BeNull $script:service.ParseDiskUsage('NOFILE')
        }

        It "returns null for a corrupt report instead of throwing" {
            Set-Content -Path (Join-Path $script:reportsDir 'BAD-folders.json') -Value '{ nope'

            Should-BeNull $script:service.ParseDiskUsage('BAD')
        }
    }
}
