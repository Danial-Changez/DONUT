using module "..\Core\TimeFormat.psm1"

<#
.SYNOPSIS
    Pure DTOs for the user Lens: a person's directory facts + their SCCM devices.

.DESCRIPTION
    The bundle the de-elevated Lens agent returns (LensAgent -> JSON): the AD user
    fields (UPN, SAM, email, manager, office) and one LensDevice per SCCM primary-device,
    each carrying its OS, last domain logon, home domain, and BitLocker recovery keys
    (read from the computer's AD object) plus model/serial/manufacturer (read from
    SCCM hardware inventory over the AdminService; SCCM also supplies the
    person->WSID affinity). WPF-free so the JSON->model parsing is unit-tested off
    a domain; PersonLensViewModel renders it. Mirrors the MachineInventory pattern.

.NOTES
    Transient (never cached in the recents store), so there is no ToHashtable round-trip -
    only FromHashtable / FromJson for parsing the agent's output.
#>
class LensBitLockerKey {
    [string] $Password = ''
    [string] $Created = ''      # ISO8601 (whenCreated of the recovery object), or ''

    static [LensBitLockerKey] FromHashtable([hashtable]$h) {
        $k = [LensBitLockerKey]::new()
        if ($null -eq $h) { return $k }
        $k.Password = [string]$h['password']
        $k.Created = [TimeFormat]::NormalizeStamp($h['created'])
        return $k
    }
}

class LensDevice {
    [string] $Name = ''
    [string] $Os = ''           # AD operatingSystem, e.g. "Windows 11 Enterprise"
    [string] $LastLogon = ''    # ISO8601 AD lastLogonTimestamp (coarse, ~14-day lag), or ''
    [string] $Domain = ''       # the computer's home AD domain (GC-located)
    [string] $Model = ''        # SCCM SMS_G_System_COMPUTER_SYSTEM.Model, or ''
    [string] $Serial = ''       # SCCM SMS_G_System_PC_BIOS.SerialNumber (Dell service tag), or ''
    [string] $Manufacturer = ''
    [LensBitLockerKey[]] $BitLockerKeys = @()
    [string] $Note = ''         # e.g. "not found in AD" / "BitLocker not escrowed"

    static [LensDevice] FromHashtable([hashtable]$h) {
        $d = [LensDevice]::new()
        if ($null -eq $h) { return $d }
        $d.Name = [string]$h['name']
        $d.Os = [string]$h['os']
        $d.LastLogon = [TimeFormat]::NormalizeStamp($h['lastLogon'])
        $d.Domain = [string]$h['domain']
        $d.Model = [string]$h['model']
        $d.Serial = [string]$h['serial']
        $d.Manufacturer = [string]$h['manufacturer']
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
    [hashtable] $Timings = @{}   # cumulative gather-stage ms, printed by debug logging

    static [PersonLens] FromHashtable([hashtable]$h) {
        $p = [PersonLens]::new()
        if ($null -eq $h) { return $p }
        $p.Upn = [string]$h['upn']
        $p.Sam = [string]$h['sam']
        $p.DisplayName = [string]$h['displayName']
        $p.Email = [string]$h['email']
        $p.Manager = [string]$h['manager']
        $p.Office = [string]$h['office']
        # $devList, not $devices: a local matching a property breaks assignment in a class.
        $devList = [System.Collections.Generic.List[LensDevice]]::new()
        foreach ($d in @($h['devices'])) {
            if ($null -ne $d) { $devList.Add([LensDevice]::FromHashtable([hashtable]$d)) }
        }
        $p.Devices = $devList.ToArray()
        $p.Errors = @(@($h['errors']) | Where-Object { $null -ne $_ } |
                ForEach-Object { [string]$_ })
        if ($h['timings'] -is [System.Collections.IDictionary]) {
            $p.Timings = [hashtable]$h['timings']
        }
        return $p
    }

    # An empty lens carrying one failure, so a caller that never got a bundle can still
    # show a reason. The UI treats any lens with Errors as the error state.
    static [PersonLens] FromError([string]$message) {
        $p = [PersonLens]::new()
        $p.Errors = @([string]$message)
        return $p
    }

    # Parses the worker's JSON bundle. -AsHashtable gives the nested hashtables that
    # FromHashtable walks, and a malformed bundle returns an empty lens with the error.
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

# One application deployment targeting the Lens person. Its own bundle, not the person
# bundle: the software lookup rides a separate request dispatched in parallel.
class LensDeployment {
    [string] $Software = ''
    [string] $Collection = ''
    [string] $Program = ''      # package rows only, apps always mean install

    static [LensDeployment] FromHashtable([hashtable]$h) {
        $d = [LensDeployment]::new()
        if ($null -eq $h) { return $d }
        $d.Software = [string]$h['software']
        $d.Collection = [string]$h['collection']
        $d.Program = [string]$h['program']
        return $d
    }

    # Parses the agent's @{ deployments, error } bundle. Malformed JSON becomes the error.
    static [hashtable] ParseBundle([string]$json) {
        $out = @{ Rows = @(); Error = '' }
        if ([string]::IsNullOrWhiteSpace($json)) { return $out }
        try {
            $h = $json | ConvertFrom-Json -AsHashtable -Depth 8
            $rowList = [System.Collections.Generic.List[LensDeployment]]::new()
            foreach ($d in @($h['deployments'])) {
                if ($null -ne $d) { $rowList.Add([LensDeployment]::FromHashtable([hashtable]$d)) }
            }
            $out.Rows = $rowList.ToArray()
            $out.Error = [string]$h['error']
        }
        catch { $out.Error = "Failed to parse the software bundle: $($_.Exception.Message)" }
        return $out
    }

    # Optional per site narrowing: keep rows whose collection matches the config regex.
    static [object[]] FilterByCollection([object[]]$rows, [string]$pattern) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { return @($rows) }
        try { return @($rows | Where-Object { [string]$_.Collection -match $pattern }) }
        catch { return @($rows) }
    }
}

# Pure formatting for the Lens (mirrors InventoryFormat and DiskUsageFormat). Static and
# WPF-free, so the device view-model just renders the result.
class LensFormat {
    # Relative "last seen" from AD's lastLogonTimestamp, which replicates with up to
    # ~14 days of lag. Blank or 0001-01-01 reads as "no logon recorded".
    static [string] LogonLabel([string]$iso) {
        if ([string]::IsNullOrWhiteSpace($iso)) { return 'no logon recorded' }
        $dt = [datetime]::MinValue
        $styles = [System.Globalization.DateTimeStyles]::RoundtripKind
        if ([datetime]::TryParse($iso, [System.Globalization.CultureInfo]::InvariantCulture,
                $styles, [ref]$dt) -and $dt -gt [datetime]::MinValue) {
            return "seen $([TimeFormat]::Relative($dt))"
        }
        return 'no logon recorded'
    }
}
