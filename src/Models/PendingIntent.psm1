<#
.SYNOPSIS
    The action a de-elevated DONUT was asked to run, carried across an elevation restart.

.DESCRIPTION
    Clicking a fleet action without administrator rights elevates and re-runs it, so
    the click survives a process swap. This is that note: what was asked for, against
    which machines, and when. The elevated instance reads it once, acts, and deletes it.

.NOTES
    A de-elevated process writes this and an elevated one reads it, so it is untrusted
    input across a privilege boundary. Two rules follow. It carries only an action kind
    and host names, never paths or arguments, so a planted file cannot widen what runs.
    And DeleteFolders is never resumable (see IsResumable): its folder list lives in the
    UI selection, cannot be rebuilt from here, and is the one destructive action.
    Resuming re-enters the normal code path, which re-applies every check it owns.
#>

# The user-initiated actions that need administrator rights. Names, not ordinals, cross
# the JSON boundary: ConvertTo-Json on an enum writes the integer.
enum GatedAction {
    RunAll
    Run
    Inventory
    DiskScan
    DeleteFolders
    StartupTask
}

class PendingIntent {
    [GatedAction] $Action = [GatedAction]::Run
    [string[]] $Hosts = @()
    [string] $CreatedUtc = ''      # ISO 8601 round-trip ('o'); '' when never stamped

    static [PendingIntent] Create([GatedAction]$action, [string[]]$hosts, [datetime]$nowUtc) {
        $intent = [PendingIntent]::new()
        $intent.Action = $action
        $intent.Hosts = @($hosts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        $intent.CreatedUtc = $nowUtc.ToUniversalTime().ToString('o')
        return $intent
    }

    # Destructive actions do not come back on their own: DeleteFolders needs a folder
    # list this note deliberately does not carry, so the user re-picks it.
    [bool] IsResumable() {
        return $this.Action -ne [GatedAction]::DeleteFolders
    }

    # Stale notes are ignored so a file left by a crash cannot fire days later.
    [bool] IsFresh([datetime]$nowUtc, [timespan]$ttl) {
        if ([string]::IsNullOrWhiteSpace($this.CreatedUtc)) { return $false }
        $created = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if (-not [datetime]::TryParse($this.CreatedUtc, [System.Globalization.CultureInfo]::InvariantCulture,
                $styles, [ref]$created)) {
            return $false
        }
        $age = $nowUtc.ToUniversalTime() - $created.ToUniversalTime()
        return ($age -ge [timespan]::Zero) -and ($age -le $ttl)
    }

    [string] ToJson() {
        return (@{
                action     = $this.Action.ToString()
                hosts      = @($this.Hosts)
                createdUtc = $this.CreatedUtc
            } | ConvertTo-Json -Compress -Depth 4)
    }

    # Anything unparseable or unrecognised yields $null: the caller then does nothing,
    # which is the safe outcome for a note it cannot vouch for.
    static [PendingIntent] FromJson([string]$json) {
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        try {
            $h = $json | ConvertFrom-Json -AsHashtable -Depth 4
            if ($null -eq $h -or -not $h['action']) { return $null }
            # Matched against the NAMES, not [enum]::TryParse: that accepts a numeric string
            # and maps '3' onto whatever member sits at ordinal 3, undefined ones included.
            $name = [string]$h['action']
            $known = @([enum]::GetNames([GatedAction]) | Where-Object { $_ -ieq $name })
            if ($known.Count -ne 1) { return $null }
            $intent = [PendingIntent]::new()
            $intent.Action = [GatedAction]$known[0]
            $intent.Hosts = @(@($h['hosts']) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { [string]$_ })
            $intent.CreatedUtc = [PendingIntent]::NormalizeStamp($h['createdUtc'])
            return $intent
        }
        catch {
            return $null
        }
    }

    # ConvertFrom-Json sniffs ISO strings into [datetime]; a bare [string] cast then
    # drops the zone marker and the instant shifts by the machine's UTC offset.
    hidden static [string] NormalizeStamp($value) {
        if ($value -is [System.DateTimeOffset]) { return $value.UtcDateTime.ToString('o') }
        if ($value -isnot [datetime]) { return [string]$value }
        # The field is UTC by contract, so an unzoned parse is taken as UTC.
        if ($value.Kind -eq [System.DateTimeKind]::Unspecified) {
            $value = [datetime]::SpecifyKind($value, [System.DateTimeKind]::Utc)
        }
        return $value.ToUniversalTime().ToString('o')
    }
}
