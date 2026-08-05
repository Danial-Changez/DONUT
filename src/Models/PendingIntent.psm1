using module "..\Core\TimeFormat.psm1"

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

# Administrator-gated actions. Names cross the JSON boundary: ConvertTo-Json writes ints.
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
    [string] $CreatedUtc = ''      # ISO 8601 round-trip ('o'), or '' when never stamped

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
            # Not [enum]::TryParse: it accepts '3' and maps it onto whatever sits at ordinal 3.
            $name = [string]$h['action']
            $known = @([enum]::GetNames([GatedAction]) | Where-Object { $_ -ieq $name })
            if ($known.Count -ne 1) { return $null }
            $intent = [PendingIntent]::new()
            $intent.Action = [GatedAction]$known[0]
            $intent.Hosts = @(@($h['hosts']) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    ForEach-Object { [string]$_ })
            $intent.CreatedUtc = [TimeFormat]::NormalizeStamp($h['createdUtc'])
            return $intent
        }
        catch {
            return $null
        }
    }
}
