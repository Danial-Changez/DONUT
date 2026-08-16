using module "..\..\src\Models\AppConfig.psm1"
using module "..\..\src\Core\NetworkProbe.psm1"
using module "..\..\src\Services\HostResolver.psm1"

Describe "HostResolver" {
    BeforeAll {
        $script:tempDir = Join-Path $TestDrive "Resolver"
        $scripts = Join-Path $script:tempDir "Scripts"
        New-Item -Path $scripts -ItemType Directory -Force | Out-Null
        foreach ($worker in 'RemoteWorker.ps1', 'ResolveWorker.ps1') {
            New-Item -Path (Join-Path $scripts $worker) `
                     -ItemType File `
                     -Force | Out-Null
        }
        $script:config = [AppConfig]::new($script:tempDir,
            (Join-Path $script:tempDir "Logs"),
            (Join-Path $script:tempDir "Reports"),
            @{})

        function New-Resolver { [HostResolver]::new($script:config, [NetworkProbe]::new()) }
    }

    Context "IP cache" {
        It "returns a cached IP and null for an unknown host" {
            $r = New-Resolver
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.GetCachedIp("PC-1") | Should -Be "10.0.0.5"
            $r.GetCachedIp("pc-1") | Should -Be "10.0.0.5"   # Case-insensitive.
            $r.GetCachedIp("PC-2") | Should -BeNullOrEmpty
        }

        It "caches a blank-IP verdict as Offline so an unresolvable host backs off, not loops" {
            # A missing entry reads 'Unknown', which the gates re-resolve forever, so cache it.
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.CacheVerdict("PC-1", "", $false)
            $r.GetCachedIp("PC-1") | Should -BeNullOrEmpty        # No usable IP.
            $r.IsHostOnline("PC-1") | Should -Be 'Offline'        # Cached, not 'Unknown'.
            $r.NeedsResolve("PC-1") | Should -BeFalse             # Backs off until the TTL.
        }

        It "tracks tri-state reachability" {
            $r = New-Resolver
            $r.IsHostOnline("PC-1") | Should -Be 'Unknown'
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.IsHostOnline("PC-1") | Should -Be 'Online'
            $r.CacheVerdict("PC-1", "10.0.0.5", $false)
            $r.IsHostOnline("PC-1") | Should -Be 'Offline'
        }
    }

    Context "NeedsResolve" {
        It "is false until a domain controller is warmed" {
            $r = New-Resolver
            $r.NeedsResolve("PC-1") | Should -BeFalse
        }

        It "is true for an unknown host once a DC is known" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.NeedsResolve("PC-1") | Should -BeTrue
        }

        It "is false for a freshly-cached host" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.NeedsResolve("PC-1") | Should -BeFalse
        }

        It "is true again once the cached verdict ages past the TTL" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.Ttl = [timespan]::FromMilliseconds(1)
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            Start-Sleep -Milliseconds 20
            $r.NeedsResolve("PC-1") | Should -BeTrue   # Stale, so re-validate.
        }

        It "is true again after Invalidate" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.Invalidate("PC-1")
            $r.NeedsResolve("PC-1") | Should -BeTrue
        }

        It "is false while a resolve is in flight (single-flight)" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.MarkInFlight("PC-1")
            $r.NeedsResolve("PC-1") | Should -BeFalse
        }

        It "ClearInFlight releases the latch so a failed resolve can be retried" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.MarkInFlight("PC-1")
            $r.NeedsResolve("PC-1") | Should -BeFalse   # Wedged while in flight.
            $r.ClearInFlight("PC-1")                    # A failed resolve releases it.
            $r.NeedsResolve("PC-1") | Should -BeTrue    # Uncached again, so re-resolves.
        }

        It "caching clears the in-flight flag" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.MarkInFlight("PC-1")
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.NeedsResolve("PC-1") | Should -BeFalse   # Cached now.
        }
    }

    Context "IsVerdictStale (gather gate)" {
        It "is false for an uncached host (nothing to distrust)" {
            $r = New-Resolver
            $r.IsVerdictStale("PC-1") | Should -BeFalse
        }

        It "is false for a freshly-cached verdict" {
            $r = New-Resolver
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $r.IsVerdictStale("PC-1") | Should -BeFalse
        }

        It "is true once the cached verdict ages past the TTL" {
            $r = New-Resolver
            $r.Ttl = [timespan]::FromMilliseconds(1)
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            Start-Sleep -Milliseconds 20
            $r.IsVerdictStale("PC-1") | Should -BeTrue
        }

        It "does not depend on a DC or in-flight state (unlike NeedsResolve)" {
            $r = New-Resolver
            $r.Ttl = [timespan]::FromMilliseconds(1)
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            Start-Sleep -Milliseconds 20
            $r.MarkInFlight("PC-1")                 # NeedsResolve would be false here.
            $r.NeedsResolve("PC-1")  | Should -BeFalse
            $r.IsVerdictStale("PC-1") | Should -BeTrue   # The verdict is still stale though.
        }
    }

    Context "worker-arg builders" {
        It "PrepareWarm tags a Resolve job in Warm mode" {
            $r = New-Resolver
            $prep = $r.PrepareWarm()
            $prep.Arguments.JobType      | Should -Be "Resolve"
            $prep.Arguments.Options.Mode | Should -Be "Warm"
        }

        It "PrepareResolve carries the host + active DC in Host mode" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $prep = $r.PrepareResolve("PC-1")
            $prep.Arguments.HostName     | Should -Be "PC-1"
            $prep.Arguments.JobType      | Should -Be "Resolve"
            $prep.Arguments.Options.Mode | Should -Be "Host"
            $prep.Arguments.Options.Dc   | Should -Be "DC1"
        }

        It "PrepareWarmRunspace tags a no-op Resolve job in WarmRunspace mode" {
            $r = New-Resolver
            $prep = $r.PrepareWarmRunspace("")
            $prep.Arguments.JobType      | Should -Be "Resolve"
            $prep.Arguments.Options.Mode | Should -Be "WarmRunspace"
            $prep.Arguments.HostName     | Should -Be ""
        }

        It "PrepareWarmRunspace rides the shell tag in HostName for the breadcrumbs" {
            $r = New-Resolver
            $prep = $r.PrepareWarmRunspace("warm-5")
            $prep.Arguments.HostName     | Should -Be "warm-5"
            $prep.Arguments.Options.Mode | Should -Be "WarmRunspace"
        }

        It "PrepareName carries the host's cached IP in Name mode" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.CacheVerdict("PC-1", "10.0.0.5", $true)
            $prep = $r.PrepareName("PC-1")
            $prep.Arguments.Options.Mode | Should -Be "Name"
            $prep.Arguments.Options.Ip   | Should -Be "10.0.0.5"
        }

        It "PrepareResolveFast targets ResolveWorker with five CLI args and no Settings" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $prep = $r.PrepareResolveFast("PC-1")
            $prep.ScriptPath | Should -Match 'ResolveWorker\.ps1$'
            $prep.Arguments.HostName | Should -Be "PC-1"
            $prep.Arguments.Dc | Should -Be "DC1"
            $prep.Arguments.Domain | Should -Be ''
            $prep.Arguments.ContainsKey('DebugLog') | Should -BeTrue
            $prep.Arguments.Keys.Count | Should -Be 5   # No Settings snapshot rides along.
        }

        It "both resolve preps carry the pick's domain hint, blank for an unhinted host" {
            $r = New-Resolver
            $r.SetActiveDc("DC1")
            $r.SetDomainHint("PC-1", " sibling.corp.local ")
            $r.PrepareResolveFast("PC-1").Arguments.Domain | Should -Be "sibling.corp.local"
            $r.PrepareResolve("PC-1").Arguments.Options.Domain | Should -Be "sibling.corp.local"
            $r.PrepareResolve("PC-2").Arguments.Options.Domain | Should -Be ''
            # A blank hint never overwrites a known domain (re-adds from recents pass none).
            $r.SetDomainHint("PC-1", "")
            $r.GetDomainHint("pc-1 ") | Should -Be "sibling.corp.local"
        }
    }

    Context "identity verdict" {
        It "is Unknown until the box reports its name" {
            $r = New-Resolver
            $r.IdentityVerdict("PC-1") | Should -Be 'Unknown'
        }
        It "Match when the reported name equals the target (case/short-name insensitive)" {
            $r = New-Resolver
            $r.CacheName("PC-1", "pc-1.contoso.local")
            $r.IdentityVerdict("PC-1") | Should -Be 'Match'
        }
        It "Mismatch when a different machine answered" {
            $r = New-Resolver
            $r.CacheName("PC-1", "OTHER-PC")
            $r.IdentityVerdict("PC-1") | Should -Be 'Mismatch'
        }
        It "ClearVerifiedName resets to Unknown" {
            $r = New-Resolver
            $r.CacheName("PC-1", "OTHER-PC")
            $r.ClearVerifiedName("PC-1")
            $r.IdentityVerdict("PC-1") | Should -Be 'Unknown'
        }
        It "Failed when the check ran but the box gave no name, unlike a check that never ran" {
            $r = New-Resolver
            $r.CacheName("PC-1", "")
            $r.IdentityVerdict("PC-1") | Should -Be 'Failed'
            $r.IdentityVerdict("PC-2") | Should -Be 'Unknown'
        }
    }
}
