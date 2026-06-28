# AdSearchResult
#
# WPF-free DTO + pure LDAP-filter helpers for the Home search bar's live AD
# finder (computers + locked-out users across the org's forests). Mirrors the
# MachineInventory / DcuProgress pure-helper pattern: the filter-building, input
# escaping and lock-state decode are unit-tested here; ActiveDirectoryService
# performs the directory I/O and the presenter renders the results.

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
            if (-not [string]::IsNullOrWhiteSpace($this.UserPrincipalName)) { return $this.UserPrincipalName }
            return $this.SamAccountName
        }
        return $this.Name
    }
}

# Pure helpers: LDAP filter construction + escaping + account-control bit decode.
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
                '\'        { [void]$sb.Append('\5c') }
                '*'        { [void]$sb.Append('\2a') }
                '('        { [void]$sb.Append('\28') }
                ')'        { [void]$sb.Append('\29') }
                ([char]0)  { [void]$sb.Append('\00') }
                default    { [void]$sb.Append($ch) }
            }
        }
        return $sb.ToString()
    }

    # Users: match the prefix against sam / cn / displayName / UPN (escaped).
    static [string] UserFilter([string]$prefix) {
        $p = [AdFilter]::EscapeLdap($prefix)
        return "(&(objectCategory=person)(objectClass=user)(|(sAMAccountName=$p*)(cn=$p*)(displayName=$p*)(userPrincipalName=$p*)))"
    }

    # Computers: match the prefix against name / sam (escaped).
    static [string] ComputerFilter([string]$prefix) {
        $p = [AdFilter]::EscapeLdap($prefix)
        return "(&(objectCategory=computer)(|(name=$p*)(sAMAccountName=$p*)))"
    }

    # Current lock state, from the constructed msDS-User-Account-Control-Computed
    # attribute (reflects live lockout, unlike a raw non-zero lockoutTime).
    static [bool] IsLockedFromComputed([object]$uacComputed) {
        return ([AdFilter]::AsInt($uacComputed) -band [AdFilter]::UF_LOCKOUT) -ne 0
    }

    # Disabled state from userAccountControl.
    static [bool] IsDisabledFromUac([object]$uac) {
        return ([AdFilter]::AsInt($uac) -band [AdFilter]::UF_ACCOUNTDISABLE) -ne 0
    }

    hidden static [int] AsInt([object]$v) {
        if ($null -eq $v) { return 0 }
        try { return [int]$v } catch { return 0 }
    }
}
