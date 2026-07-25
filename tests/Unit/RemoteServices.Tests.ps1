using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Models\RemoteError.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\..\src\Services\DriverMatchingService.psm1"
using module "..\..\src\Services\RemoteServices.psm1"
using module "..\Helpers\CapturingLogService.psm1"
using namespace System.Net

# Mock NetworkProbe for testing
class MockNetworkProbe : NetworkProbe {
    [bool] $IsOnlineResult = $true
    [bool] $IsRpcAvailableResult = $true
    [IPAddress] $ResolveHostResult = [IPAddress]::Parse("127.0.0.1")
    [bool] $ReverseDnsResult = $true

    MockNetworkProbe() {}

    [bool] IsOnline([string]$hostName) { return $this.IsOnlineResult }
    [bool] IsRpcAvailable([string]$hostName) { return $this.IsRpcAvailableResult }
    [IPAddress] ResolveHost([string]$hostName) { return $this.ResolveHostResult }
    [bool] CheckReverseDNS([IPAddress]$ip, [string]$hostName) { return $this.ReverseDnsResult }
}

Describe "RemoteServices" {
    
    BeforeAll {
        # Setup
        $tempDir = Join-Path $env:TEMP "DonutTests_Remote"
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
        $scriptsDir = Join-Path $tempDir "Scripts"
        if (-not (Test-Path $scriptsDir)) { New-Item -Path $scriptsDir -ItemType Directory -Force | Out-Null }
        New-Item -Path (Join-Path $scriptsDir "RemoteWorker.ps1") -ItemType File -Force | Out-Null
        
        $config = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{})
    }

    AfterAll {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    Context "ScanService" {
        It "Should initialize correctly" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)
            $service | Should -Not -BeNullOrEmpty
        }

        It "PrepareScan should return correct arguments (no network on the UI thread)" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")

            # Pester 5 assertions
            $result.ScriptPath | Should -Match "Scripts\\RemoteWorker.ps1$"
            $result.Arguments.HostName | Should -Be "TestHost"
            $result.Arguments.JobType | Should -Be "Scan"
        }

        It "PrepareScan does NOT probe connectivity (that is the worker's job, off the UI thread)" {
            # An offline host must not make the UI-thread Prepare* block or throw;
            # reachability is asserted later by the worker on the runspace pool.
            $probe = [MockNetworkProbe]::new()
            $probe.IsOnlineResult = $false
            $service = [ScanService]::new($config, $probe)

            { $service.PrepareScan("OfflineHost") } | Should -Not -Throw
        }
    }

    Context "RemoteUpdateService" {
        It "Should initialize correctly" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)
            $service | Should -Not -BeNullOrEmpty
        }

        It "PrepareScanForUpdates should return correct arguments" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $result = $service.PrepareScanForUpdates("TestHost")
            
            $result.Arguments.JobType | Should -Be "Scan"
        }

        It "PrepareApplyUpdates should return correct arguments" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)
            
            $updates = @{ "KB123456" = "Security Update" }
            $result = $service.PrepareApplyUpdates("TestHost", $updates)

            $result.Arguments.JobType | Should -Be "Apply"
            # Snapshot contract: same content, never the caller's live reference.
            $result.Arguments.Options['KB123456'] | Should -Be "Security Update"
            [object]::ReferenceEquals($result.Arguments.Options, $updates) | Should -BeFalse
        }
    }

    Context "ParseUpdateReport" {
        BeforeAll {
            $script:reportsDir = Join-Path $tempDir "Reports"
            if (-not (Test-Path $script:reportsDir)) {
                New-Item -Path $script:reportsDir -ItemType Directory -Force | Out-Null
            }
        }

        It "Should return null when report file does not exist" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $result = $service.ParseUpdateReport("NonExistentHost")
            
            $result | Should -BeNullOrEmpty
        }

        It "Should parse valid XML report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            # Real DCU report shape: each field is a CHILD element, not an attribute.
            $testXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<updates>
    <update>
        <name>Dell Latitude 5330 System BIOS</name>
        <version>1.36.0</version>
        <urgency>Urgent</urgency>
        <type>BIOS</type>
        <category>BIOS</category>
        <bytes>28033352</bytes>
    </update>
    <update>
        <name>Realtek High Definition Audio Driver</name>
        <version>6.0.9954.2</version>
        <urgency>Recommended</urgency>
        <type>Driver</type>
        <category>Audio</category>
        <bytes>264884984</bytes>
    </update>
</updates>
"@
            $reportPath = Join-Path $script:reportsDir "TestHost-Updates.xml"
            Set-Content -Path $reportPath -Value $testXml

            $result = $service.ParseUpdateReport("TestHost")

            $result | Should -Not -BeNullOrEmpty
            $nodes = $result.SelectNodes("//update")
            $nodes.Count | Should -Be 2
            # Read fields via SelectSingleNode (never $node.name - it collides with XmlElement.Name).
            $nodes[0].SelectSingleNode("name").InnerText | Should -Be "Dell Latitude 5330 System BIOS"
            $nodes[0].SelectSingleNode("urgency").InnerText | Should -Be "Urgent"

            # Cleanup
            Remove-Item -Path $reportPath -Force -ErrorAction SilentlyContinue
        }

        It "Caches the parsed report until the file's mtime changes" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $reportPath = Join-Path $script:reportsDir "CacheHost-Updates.xml"
            Set-Content -Path $reportPath -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<updates><update name="A" version="1"/></updates>
"@

            $r1 = $service.ParseUpdateReport("CacheHost")
            $r2 = $service.ParseUpdateReport("CacheHost")
            # Same file -> same cached instance (not re-parsed).
            [object]::ReferenceEquals($r1, $r2) | Should -BeTrue
            $service.CountUpdates($r1) | Should -Be 1

            # Rewrite with a newer mtime -> cache miss -> fresh parse with new content.
            Set-Content -Path $reportPath -Value @"
<?xml version="1.0" encoding="UTF-8"?>
<updates><update name="A" version="1"/><update name="B" version="2"/></updates>
"@
            (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddSeconds(5)

            $r3 = $service.ParseUpdateReport("CacheHost")
            [object]::ReferenceEquals($r1, $r3) | Should -BeFalse
            $service.CountUpdates($r3) | Should -Be 2

            Remove-Item -Path $reportPath -Force -ErrorAction SilentlyContinue
        }

        It "Should return null for malformed XML" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            # Create an invalid XML file
            $reportPath = Join-Path $script:reportsDir "BadHost-Updates.xml"
            Set-Content -Path $reportPath -Value "This is not valid XML <unclosed"

            $result = $service.ParseUpdateReport("BadHost")
            
            $result | Should -BeNullOrEmpty

            # Cleanup
            Remove-Item -Path $reportPath -Force -ErrorAction SilentlyContinue
        }
    }

    Context "CountUpdates" {
        It "Returns 0 for a null report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            $service.CountUpdates($null) | Should -Be 0
        }

        It "Counts //update nodes in a report" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            [xml]$report = @"
<updates>
    <update name="BIOS" version="1.0"/>
    <update name="Audio" version="2.0"/>
    <update name="Video" version="3.0"/>
</updates>
"@
            $service.CountUpdates($report) | Should -Be 3
        }

        It "Returns 0 when there are no update nodes" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $service = [RemoteUpdateService]::new($config, $probe, $matcher)

            [xml]$report = "<updates></updates>"
            $service.CountUpdates($report) | Should -Be 0
        }
    }

    Context "GetUpdateRows (typed rows for the detail pane)" {
        BeforeAll {
            $script:rowsReportsDir = Join-Path $tempDir "Reports"
            if (-not (Test-Path $script:rowsReportsDir)) {
                New-Item -Path $script:rowsReportsDir -ItemType Directory -Force | Out-Null
            }
            # Real DCU shape: update fields are CHILD elements; installed drivers are attributes.
            $script:rowsXml = @"
<?xml version="1.0" encoding="UTF-8"?>
<updates>
    <drivers>
        <driver name="Realtek High Definition Audio Driver" provider="Realtek"
                version="6.0.9000.1" date="2024-01-01"/>
    </drivers>
    <update>
        <name>ZWidget Dock Firmware</name>
        <version>2.0.0</version>
        <urgency>Optional</urgency>
        <type>Firmware</type>
        <category>Docks</category>
        <bytes>1048576</bytes>
    </update>
    <update>
        <name>Dell Latitude 5330 System BIOS</name>
        <version>1.36.0</version>
        <urgency>Urgent</urgency>
        <type>BIOS</type>
        <category>BIOS</category>
        <bytes>28033352</bytes>
    </update>
    <update>
        <name>Realtek High Definition Audio Driver</name>
        <version>6.0.9954.2</version>
        <urgency>Recommended</urgency>
        <type>Driver</type>
        <category></category>
        <bytes>264884984</bytes>
    </update>
</updates>
"@
            $script:rowsService = [RemoteUpdateService]::new(
                $config, [MockNetworkProbe]::new(), [DriverMatchingService]::new())
            Set-Content -Path (Join-Path $script:rowsReportsDir "RowsHost-Updates.xml") -Value $script:rowsXml
        }

        AfterAll {
            Remove-Item -Path (Join-Path $script:rowsReportsDir "RowsHost-Updates.xml") -Force -ErrorAction SilentlyContinue
        }

        It "Returns null when no report exists (distinct from a zero-update report)" {
            $rows = $script:rowsService.GetUpdateRows("NoSuchHost")
            $null -eq $rows | Should -BeTrue
        }

        It "Returns an empty array for a report with zero updates" {
            $emptyPath = Join-Path $script:rowsReportsDir "EmptyHost-Updates.xml"
            Set-Content -Path $emptyPath -Value "<updates></updates>"

            $rows = $script:rowsService.GetUpdateRows("EmptyHost")

            $null -ne $rows | Should -BeTrue
            $rows.Count | Should -Be 0
            Remove-Item -Path $emptyPath -Force -ErrorAction SilentlyContinue
        }

        It "Sorts rows most-urgent first (Urgent -> Recommended -> Optional)" {
            $rows = $script:rowsService.GetUpdateRows("RowsHost")

            $rows.Count | Should -Be 3
            $rows[0].Urgency | Should -Be "Urgent"
            $rows[1].Urgency | Should -Be "Recommended"
            $rows[2].Urgency | Should -Be "Optional"
        }

        It "Reads child elements explicitly (never the XmlElement.Name collision)" {
            $rows = $script:rowsService.GetUpdateRows("RowsHost")

            # A mashed InnerText/tag-name read would never produce these exact fields.
            $rows[0].Name | Should -Be "Dell Latitude 5330 System BIOS"
            $rows[0].SizeText | Should -Be "26.7 MB"
            $rows[2].Type | Should -Be "Firmware"
        }

        It "Merges a driver match: version transition, IsNewer, and category backfill" {
            $rows = $script:rowsService.GetUpdateRows("RowsHost")
            $audio = $rows | Where-Object Name -Like "Realtek*"

            $audio.HasMatch | Should -BeTrue
            $audio.IsNewer | Should -BeTrue
            $audio.VersionText | Should -Match "6\.0\.9000\.1"    # installed baseline shown
            $audio.Category | Should -Not -BeNullOrEmpty          # backfilled from the match
        }

        It "Leaves unmatched rows with the target version alone" {
            $rows = $script:rowsService.GetUpdateRows("RowsHost")
            $bios = $rows | Where-Object Name -Like "*BIOS*"

            $bios.HasMatch | Should -BeFalse
            $bios.VersionText | Should -Be "1.36.0"
        }
    }

    # The worker phases gate their own transport and throw typed failures directly;
    # RemoteJobService.Fail is the shared log-then-throw policy they route through
    # (ResolvedIpFor, RunInventoryPhase), so the log entry and the exception can
    # never drift apart. Exercised directly here.
    Context "Fail (typed failures log at their carried severity)" {
        It "Logs a Warning-level failure as WARN and returns the exception to throw" {
            $log = [CapturingLogService]::new()
            $ex = [RemoteJobService]::Fail($log, [HostOfflineException]::new('PC-OFF'))
            $ex.GetType().Name | Should -Be 'HostOfflineException'
            $ex.HostName | Should -Be 'PC-OFF'
            $log.HasLevel('WARN') | Should -BeTrue
            $log.Contains('offline') | Should -BeTrue
        }

        It "Logs an Error-level failure as ERROR" {
            $log = [CapturingLogService]::new()
            $ex = [RemoteJobService]::Fail($log, [RpcUnavailableException]::new('PC-RPC'))
            $ex.GetType().Name | Should -Be 'RpcUnavailableException'
            $log.HasLevel('ERROR') | Should -BeTrue
        }
    }

    Context "Logging" {
        It "Should default to a no-op logger when constructed without one" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $service.Logger | Should -Not -BeNullOrEmpty
        }
    }

    Context "BuildWorkerArgs" {
        It "Should throw when RemoteWorker script is missing" {
            # Create config pointing to empty directory
            $emptyDir = Join-Path $env:TEMP "DonutTests_Empty_$(Get-Random)"
            New-Item -Path $emptyDir -ItemType Directory -Force | Out-Null
            
            $emptyConfig = [AppConfig]::new($emptyDir, (Join-Path $emptyDir "Logs"), (Join-Path $emptyDir "Reports"), @{})
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($emptyConfig, $probe)

            { $service.PrepareScan("TestHost") } | Should -Throw "*RemoteWorker script not found*"

            # Cleanup
            Remove-Item -Path $emptyDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        It "Should include SourceRoot in arguments" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")
            
            $result.Arguments.SourceRoot | Should -Be $config.SourceRoot
        }

        It "Should include LogsDir and ReportsDir in arguments" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            $result = $service.PrepareScan("TestHost")

            $result.Arguments.LogsDir | Should -Be $config.LogsPath
            $result.Arguments.ReportsDir | Should -Be $config.ReportsPath
        }

        It "Should send a config Settings snapshot so the worker need not re-read config.json" {
            $probe = [MockNetworkProbe]::new()
            $cfg = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{
                activeCommand = "applyUpdates"
            })
            $service = [ScanService]::new($cfg, $probe)

            $result = $service.PrepareScan("TestHost")

            $result.Arguments.Settings.activeCommand | Should -Be "applyUpdates"
            # A SNAPSHOT, never the live reference: the worker deep-enumerates this
            # hashtable off-thread, and enumerating a live table the UI thread is
            # writing can corrupt it and spin forever (a silent pure-CPU wedge).
            [object]::ReferenceEquals($result.Arguments.Settings, $cfg.Settings) |
                Should -BeFalse -Because (
                "jobs must carry a UI-thread deep clone of Settings, not the live " +
                "reference the UI keeps mutating")
        }

        It "Should carry Settings on apply-phase arguments too" {
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $cfg = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{
                activeCommand = "applyUpdates"
            })
            $service = [RemoteUpdateService]::new($cfg, $probe, $matcher)

            $result = $service.PrepareApplyUpdates("TestHost", @{})

            $result.Arguments.Settings.activeCommand | Should -Be "applyUpdates"
        }

        It "Should carry the logger's effective debug state as the DebugLog arg" {
            $probe = [MockNetworkProbe]::new()
            $service = [ScanService]::new($config, $probe)

            # Constructed without a logger -> NullLogService, whose class default is
            # verbose; the arg mirrors whatever the injected logger's gate says.
            $service.PrepareScan("TestHost").Arguments.DebugLog | Should -BeTrue

            $service.Logger.DebugEnabled = $false
            $service.PrepareScan("TestHost").Arguments.DebugLog | Should -BeFalse
        }

        It "Should carry an Options snapshot, never the live reference" {
            # Same rule as Settings: apply's selected-updates table is UI state, and
            # a worker enumerating a live table the UI mutates can spin forever.
            $probe = [MockNetworkProbe]::new()
            $matcher = [DriverMatchingService]::new()
            $cfg = [AppConfig]::new($tempDir, (Join-Path $tempDir "Logs"), (Join-Path $tempDir "Reports"), @{})
            $service = [RemoteUpdateService]::new($cfg, $probe, $matcher)
            $selected = @{ 'KB123' = @{ name = 'driver' } }

            $result = $service.PrepareApplyUpdates("TestHost", $selected)

            $result.Arguments.Options['KB123'].name | Should -Be 'driver'
            [object]::ReferenceEquals($result.Arguments.Options, $selected) |
                Should -BeFalse -Because (
                "no live hashtable may cross the runspace boundary")
        }
    }
}
