using module "..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    Pure DTOs for the user Lens: a person's directory facts + their SCCM devices.

.DESCRIPTION
    The bundle the de-elevated lens lookup returns (LensWorker -> JSON): the AD user
    fields (UPN, SAM, email, manager, office) and one LensDevice per SCCM primary-device,
    each carrying its model, last hardware-sync, home domain, and BitLocker recovery keys.
    WPF-free so the JSON->model parsing is unit-tested off a domain; PersonLensViewModel
    renders it. Mirrors the MachineInventory / AdSearchResult pure-DTO pattern.

.NOTES
    Transient (never cached in the recents store), so there is no ToHashtable round-trip -
    only FromHashtable / FromJson for parsing the worker's output.
#>
class LensBitLockerKey {
    [string] $Password = ''
    [string] $Created = ''      # ISO8601 (whenCreated of the recovery object), or ''

    static [LensBitLockerKey] FromHashtable([hashtable]$h) {
        $k = [LensBitLockerKey]::new()
        if ($null -eq $h) { return $k }
        $k.Password = [string]$h['password']
        $k.Created = [string]$h['created']
        return $k
    }
}

class LensDevice {
    [string] $Name = ''
    [string] $Model = ''
    [string] $LastSync = ''     # ISO8601 last hardware-sync / agent time, or ''
    [string] $Domain = ''       # the computer's home AD domain (GC-located)
    [LensBitLockerKey[]] $BitLockerKeys = @()
    [string] $Note = ''         # e.g. "not found in AD" / "BitLocker not escrowed"

    static [LensDevice] FromHashtable([hashtable]$h) {
        $d = [LensDevice]::new()
        if ($null -eq $h) { return $d }
        $d.Name = [string]$h['name']
        $d.Model = [string]$h['model']
        $d.LastSync = [string]$h['lastSync']
        $d.Domain = [string]$h['domain']
        $d.Note = [string]$h['note']
        $keys = [System.Collections.Generic.List[LensBitLockerKey]]::new()
        foreach ($bk in @($h['bitLockerKeys'])) {
            if ($null -ne $bk) { $keys.Add([LensBitLockerKey]::FromHashtable([hashtable]$bk)) }
        }
        $d.BitLockerKeys = $keys.ToArray()
        return $d
    }

    [bool] HasBitLocker() { return $this.BitLockerKeys.Count -gt 0 }
}

class PersonLens {
    [string] $Upn = ''
    [string] $Sam = ''
    [string] $DisplayName = ''
    [string] $Email = ''
    [string] $Manager = ''
    [string] $Office = ''
    [LensDevice[]] $Devices = @()
    [string[]] $Errors = @()     # per-section failures (worker still returns what it could)

    static [PersonLens] FromHashtable([hashtable]$h) {
        $p = [PersonLens]::new()
        if ($null -eq $h) { return $p }
        $p.Upn = [string]$h['upn']
        $p.Sam = [string]$h['sam']
        $p.DisplayName = [string]$h['displayName']
        $p.Email = [string]$h['email']
        $p.Manager = [string]$h['manager']
        $p.Office = [string]$h['office']
        # $devList, not $devices: a local matching the $Devices property (case-insensitive)
        # breaks assignment inside a PS class method.
        $devList = [System.Collections.Generic.List[LensDevice]]::new()
        foreach ($d in @($h['devices'])) {
            if ($null -ne $d) { $devList.Add([LensDevice]::FromHashtable([hashtable]$d)) }
        }
        $p.Devices = $devList.ToArray()
        $p.Errors = @(@($h['errors']) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
        return $p
    }

    # Parses the worker's JSON bundle. -AsHashtable gives nested hashtables/arrays that
    # FromHashtable walks; a malformed bundle returns an empty lens carrying the error.
    static [PersonLens] FromJson([string]$json) {
        if ([string]::IsNullOrWhiteSpace($json)) { return [PersonLens]::new() }
        try {
            $h = $json | ConvertFrom-Json -AsHashtable -Depth 8
            return [PersonLens]::FromHashtable([hashtable]$h)
        }
        catch {
            $p = [PersonLens]::new()
            $p.Errors = @("Failed to parse the lens bundle: $($_.Exception.Message)")
            return $p
        }
    }
}

# Pure formatting for the Lens (mirrors InventoryFormat / DiskUsageFormat). Static, WPF-free,
# unit-tested; the device view-model just renders the result.
class LensFormat {
    # Relative "last synced" from the SCCM last-hardware-scan time. Blank or 0001-01-01
    # (never inventoried) reads as "never synced".
    static [string] SyncLabel([string]$iso) {
        if ([string]::IsNullOrWhiteSpace($iso)) { return 'never synced' }
        $dt = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($iso, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$dt) -and $dt -gt [datetime]::MinValue) {
            return "synced $([TimeFormat]::Relative($dt))"
        }
        return 'never synced'
    }
}
