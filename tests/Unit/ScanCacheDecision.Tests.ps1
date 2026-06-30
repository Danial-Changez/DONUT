using module "..\..\src\Models\ScanCacheDecision.psm1"

Describe "ScanCacheDecision.IsFresh" {
    BeforeAll {
        $script:now = [datetime]::new(2026, 6, 29, 12, 0, 0, [System.DateTimeKind]::Utc)
        $script:ttl = [timespan]::FromHours(24)
    }

    It "is fresh for an UpdateScan within 24h with a report on disk" {
        $seen = $script:now.AddHours(-2)
        [ScanCacheDecision]::IsFresh('UpdateScan', $seen, $script:now, $script:ttl, $true) | Should -BeTrue
    }

    It "is fresh for a plain Scan within 24h with a report" {
        $seen = $script:now.AddHours(-23)
        [ScanCacheDecision]::IsFresh('Scan', $seen, $script:now, $script:ttl, $true) | Should -BeTrue
    }

    It "is NOT fresh after a successful apply (last job is UpdateApply)" {
        $seen = $script:now.AddMinutes(-5)
        [ScanCacheDecision]::IsFresh('UpdateApply', $seen, $script:now, $script:ttl, $true) | Should -BeFalse
    }

    It "is NOT fresh once the scan ages past the TTL" {
        $seen = $script:now.AddHours(-25)
        [ScanCacheDecision]::IsFresh('UpdateScan', $seen, $script:now, $script:ttl, $true) | Should -BeFalse
    }

    It "is NOT fresh when the report file is gone" {
        $seen = $script:now.AddHours(-1)
        [ScanCacheDecision]::IsFresh('UpdateScan', $seen, $script:now, $script:ttl, $false) | Should -BeFalse
    }

    It "is NOT fresh for a never-run host (MinValue lastSeen)" {
        [ScanCacheDecision]::IsFresh('Scan', [datetime]::MinValue, $script:now, $script:ttl, $true) | Should -BeFalse
    }

    It "is NOT fresh for a non-scan last job (e.g. Inventory/DiskScan)" {
        $seen = $script:now.AddHours(-1)
        [ScanCacheDecision]::IsFresh('Inventory', $seen, $script:now, $script:ttl, $true) | Should -BeFalse
    }
}
