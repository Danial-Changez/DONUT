using module "..\Core\LogService.psm1"
using module "..\Models\AdSearchResult.psm1"

# ActiveDirectoryService
#
# Live AD search (computers + users) across the org's separate forests, plus
# unlocking locked-out user accounts. Mirrors NetworkProbe's seam pattern: the
# env-coupled directory I/O is isolated in overridable hidden seams
# (QueryDirectory, InvokeUnlock) so the multi-domain aggregation / mapping /
# guard logic is unit-testable off a domain by subclassing and faking the seams.
#
# Each forest is queried independently (no shared Global Catalog spans them); a
# down or untrusted forest is skipped + logged so the others still return.

class ActiveDirectoryService {
    [LogService] $Logger
    [string[]]   $Domains = @()
    [int]        $MinPrefix = 3
    [int]        $MaxPerDomain = 8

    ActiveDirectoryService() {
        $this.Logger = [NullLogService]::new()
    }

    ActiveDirectoryService([string[]]$domains, [LogService]$logger) {
        $this.Domains = @($domains | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $this.Logger = [LogService]::Coalesce($logger)
    }

    # Searches every configured forest for computers + users matching the prefix.
    [AdSearchResult[]] Search([string]$prefix) {
        $results = [System.Collections.Generic.List[AdSearchResult]]::new()
        if ([string]::IsNullOrWhiteSpace($prefix) -or $prefix.Trim().Length -lt $this.MinPrefix) {
            return $results.ToArray()
        }
        $p = $prefix.Trim()
        $seen = [System.Collections.Generic.HashSet[string]]::new()

        $specs = @(
            @{ Kind = 'Computer'; Filter = [AdFilter]::ComputerFilter($p);
               Props = @('name', 'sAMAccountName', 'userAccountControl', 'distinguishedName') }
            @{ Kind = 'User'; Filter = [AdFilter]::UserFilter($p);
               Props = @('sAMAccountName', 'userPrincipalName', 'displayName', 'name',
                         'msDS-User-Account-Control-Computed', 'userAccountControl', 'distinguishedName') }
        )

        foreach ($domain in $this.Domains) {
            foreach ($spec in $specs) {
                try {
                    $rows = $this.QueryDirectory($domain, $spec.Filter, $spec.Props, $this.MaxPerDomain)
                    foreach ($row in $rows) {
                        $item = $this.MapRow($spec.Kind, $domain, $row)
                        if ($null -ne $item -and $seen.Add($item.Key())) {
                            $results.Add($item)
                        }
                    }
                }
                catch {
                    $this.Logger.LogWarning("AD search in '$domain' ($($spec.Kind)) failed: $($_.Exception.Message)")
                }
            }
        }
        return $results.ToArray()
    }

    # Unlocks a locked-out user against its home domain. Returns success.
    [bool] UnlockUser([AdSearchResult]$user) {
        if ($null -eq $user -or $user.Kind -ne 'User' -or [string]::IsNullOrWhiteSpace($user.SamAccountName)) {
            return $false
        }
        try {
            $this.InvokeUnlock($user.SamAccountName, $user.Domain)
            $this.Logger.LogInfo("Unlocked AD account $($user.SamAccountName) in $($user.Domain).")
            return $true
        }
        catch {
            $this.Logger.LogException("Failed to unlock $($user.SamAccountName) in $($user.Domain)", $_)
            return $false
        }
    }

    # --- pure mapping (exercised via Search in tests) ---------------------------
    hidden [AdSearchResult] MapRow([string]$kind, [string]$domain, [hashtable]$row) {
        if ($null -eq $row) { return $null }
        $r = [AdSearchResult]::new()
        $r.Kind = $kind
        $r.Domain = $domain
        $r.Name = [string]$row['name']
        # Computer sAMAccountNames carry a trailing '$'; strip it for display/identity.
        $r.SamAccountName = ([string]$row['sAMAccountName']).TrimEnd('$')
        $r.DistinguishedName = [string]$row['distinguishedName']
        $r.Enabled = -not [AdFilter]::IsDisabledFromUac($row['userAccountControl'])
        if ($kind -eq 'User') {
            $r.UserPrincipalName = [string]$row['userPrincipalName']
            $r.DisplayName = [string]$row['displayName']
            $r.LockedOut = [AdFilter]::IsLockedFromComputed($row['msDS-User-Account-Control-Computed'])
        }
        return $r
    }

    # --- env-coupled seams (overridden in tests) --------------------------------

    # Runs an LDAP search against one forest, returning rows as property
    # hashtables. DirectorySearcher (not the AD module) keeps this fast and
    # importable into a background runspace without loading RSAT per query.
    hidden [hashtable[]] QueryDirectory([string]$domain, [string]$filter, [string[]]$props, [int]$max) {
        Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry)
        try {
            $searcher.Filter = $filter
            $searcher.SizeLimit = $max
            $searcher.ClientTimeout = [TimeSpan]::FromSeconds(5)
            foreach ($pr in $props) { [void]$searcher.PropertiesToLoad.Add($pr) }

            $rows = [System.Collections.Generic.List[hashtable]]::new()
            $found = $searcher.FindAll()
            try {
                foreach ($res in $found) {
                    $h = @{}
                    foreach ($pr in $props) {
                        if ($res.Properties.Contains($pr) -and $res.Properties[$pr].Count -gt 0) {
                            $h[$pr] = $res.Properties[$pr][0]
                        }
                    }
                    $rows.Add($h)
                }
            }
            finally { $found.Dispose() }
            return $rows.ToArray()
        }
        finally {
            $searcher.Dispose()
            $entry.Dispose()
        }
    }

    # Unlocks via the AD module against the user's home domain (one-shot).
    hidden [void] InvokeUnlock([string]$sam, [string]$domain) {
        Unlock-ADAccount -Identity $sam -Server $domain -ErrorAction Stop
    }
}
