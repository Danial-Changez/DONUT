<#
.SYNOPSIS
    WPF-free DTO + pure LDAP-filter helpers for the Home live AD finder.

.DESCRIPTION
    Backs the search bar's AD finder (computers + locked-out users across the
    org's forests). AdSearchResult is the per-hit DTO; AdFilter builds the LDAP
    filters, escapes input, and decodes the lock/disable bits. Mirrors the
    MachineInventory / DcuProgress pure-helper pattern: the filter-building,
    escaping and lock-state decode are unit-tested here; ActiveDirectoryService
    performs the directory I/O and the presenter renders the results.
#>
class AdSearchResult {
    [string] $Kind = 'Computer'      # 'Computer' | 'User'
    [string] $Name = ''
    [string] $SamAccountName = ''
    [string] $UserPrincipalName = ''
    [string] $DisplayName = ''
    [string] $Domain = ''
    [bool]   $Enabled = $true
    [bool]   $LockedOut = $false
    [string] $DistinguishedName = ''

    # Stable identity for dedupe across overlapping forest results.
    [string] Key() {
        return ($this.Kind + '|' + $this.Domain + '\' + $this.SamAccountName).ToLowerInvariant()
    }

    # Best label for the dropdown: UPN for users (fallback sam), name for computers.
    [string] Label() {
        if ($this.Kind -eq 'User') {
            if (-not [string]::IsNullOrWhiteSpace($this.UserPrincipalName)) {
                return $this.UserPrincipalName
            }
            return $this.SamAccountName
        }
        return $this.Name
    }
}

<#
.SYNOPSIS
    Orders finder rows so the strongest match leads, and says how many were held back.

.NOTES
    Exists because UserFilter matches sn as well now. A surname hit is worth having - it is
    the whole reason sn was added - but it must not outrank the name the user is typing,
    since people type a first name far more often than a surname.

    Rows arrive as PSCustomObjects marshalled out of AdSearchWorker, not as AdSearchResult,
    so Of reads its fields duck-typed and works for either shape.

    The last tier is inferred, not read. sn is deliberately NOT in the finder's
    PropertiesToLoad, so a row that matches none of the four visible fields can only have
    arrived via the sn clause - which makes "matched nothing you can see" a reliable
    surname-only signal without paying for another attribute on every search.

    Order sorts on materialised properties rather than Sort-Object script blocks, because a
    script block evaluated by Sort-Object cannot see $prefix from inside a class method.
#>
class AdSearchRank {
    # Lower sorts first: displayName, then cn/name, then sam, then UPN, then surname-only.
    static [int] Of([object]$row, [string]$prefix) {
        if ($null -eq $row -or [string]::IsNullOrWhiteSpace($prefix)) { return 99 }
        $p = $prefix.Trim()
        $fields = @([string]$row.DisplayName, [string]$row.Name,
            [string]$row.SamAccountName, [string]$row.UserPrincipalName)
        for ($i = 0; $i -lt $fields.Count; $i++) {
            if ($fields[$i].StartsWith($p, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $i
            }
        }
        return $fields.Count
    }

    # Rank first, then name, so a re-render never reshuffles rows under the cursor.
    static [object[]] Order([object[]]$rows, [string]$prefix) {
        $keyed = [System.Collections.Generic.List[object]]::new()
        foreach ($r in $rows) {
            $keyed.Add([pscustomobject]@{
                    Rank = [AdSearchRank]::Of($r, $prefix)
                    Tie  = "$([string]$r.DisplayName)|$([string]$r.SamAccountName)"
                    Row  = $r
                })
        }
        return @($keyed | Sort-Object Rank, Tie | ForEach-Object { $_.Row })
    }
}

class AdFilter {
    static [int] $UF_ACCOUNTDISABLE = 0x0002
    static [int] $UF_LOCKOUT        = 0x0010

    # RFC 2254 / 4515 LDAP filter escaping. Prevents a typed '*', '(' etc. from
    # breaking the filter or injecting extra clauses.
    static [string] EscapeLdap([string]$text) {
        if ([string]::IsNullOrEmpty($text)) { return '' }
        $sb = [System.Text.StringBuilder]::new()
        foreach ($ch in $text.ToCharArray()) {
            switch ($ch) {
                '\' { [void]$sb.Append('\5c') }
                '*' { [void]$sb.Append('\2a') }
                '(' { [void]$sb.Append('\28') }
                ')' { [void]$sb.Append('\29') }
                ([char]0) { [void]$sb.Append('\00') }
                default { [void]$sb.Append($ch) }
            }
        }
        return $sb.ToString()
    }

    # Users: match the prefix against sam / cn / displayName / UPN / sn (escaped). sn is
    # explicit rather than via ANR, which would also drag in office and proxyAddresses.
    static [string] UserFilter([string]$prefix) {
        $p = [AdFilter]::EscapeLdap($prefix)
        return "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$p*)(cn=$p*)(displayName=$p*)(userPrincipalName=$p*)(sn=$p*)))"
    }

    # Computers: match the prefix against name / sam (escaped).
    static [string] ComputerFilter([string]$prefix) {
        $p = [AdFilter]::EscapeLdap($prefix)
        return "(&(objectCategory=computer)(|(name=$p*)(sAMAccountName=$p*)))"
    }

    # Computers or users in one filter, so a forest is bound + queried once per search
    # instead of twice. Each row's kind is recovered from objectCategory by the caller.
    static [string] CombinedFilter([string]$prefix) {
        return "(|$([AdFilter]::ComputerFilter($prefix))$([AdFilter]::UserFilter($prefix)))"
    }

    # Current lock state, from the constructed msDS-User-Account-Control-Computed
    # attribute (reflects live lockout, unlike a raw non-zero lockoutTime).
    static [bool] IsLockedFromComputed([object]$uacComputed) {
        return ([AdFilter]::AsInt($uacComputed) -band [AdFilter]::UF_LOCKOUT) -ne 0
    }

    static [bool] IsDisabledFromUac([object]$uac) {
        return ([AdFilter]::AsInt($uac) -band [AdFilter]::UF_ACCOUNTDISABLE) -ne 0
    }

    hidden static [int] AsInt([object]$v) {
        if ($null -eq $v) { return 0 }
        try { return [int]$v } catch { return 0 }
    }
}
