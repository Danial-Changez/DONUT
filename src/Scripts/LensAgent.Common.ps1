#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for LensAgent.ps1: crypto/exchange I/O and the AD/SCCM lookup
    (Resolve-Lens).

.DESCRIPTION
    Dot-sourced by LensAgent.ps1 in the agent's main runspace, and by each lookup
    ThreadJob the serve loop spawns (a slow lookup runs off the loop so the loop stays
    free for the next request). Callers must set these script-scope variables before use:
      $script:KeyIv      48-byte AES key+IV (from key.bin)
      $script:ForestNc   the forest root naming context (for GC binds)
      $ExchangeDir       the ACL-locked exchange directory

.NOTES
    Crypto format MUST match PersonLensService.ProtectText/UnprotectText. The Lens
    lookup logic here is unchanged from its previous inline home in LensAgent.ps1.
#>

# --- Crypto + atomic file I/O (format shared with PersonLensService) ---
function Protect-Text([string]$text) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = [byte[]]($script:KeyIv[0..31]); $aes.IV = [byte[]]($script:KeyIv[32..47])
        $enc = $aes.CreateEncryptor()
        $plain = [Text.Encoding]::UTF8.GetBytes($text)
        return $enc.TransformFinalBlock($plain, 0, $plain.Length)
    }
    finally { $aes.Dispose() }
}

function Unprotect-File([string]$path) {
    $aes = [System.Security.Cryptography.Aes]::Create()
    try {
        $aes.Key = [byte[]]($script:KeyIv[0..31]); $aes.IV = [byte[]]($script:KeyIv[32..47])
        $dec = $aes.CreateDecryptor()
        $blob = [IO.File]::ReadAllBytes($path)
        return [Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($blob, 0, $blob.Length))
    }
    finally { $aes.Dispose() }
}

function Write-LensBundle([string]$path, [string]$json) {
    $tmp = "$path.tmp"
    [IO.File]::WriteAllBytes($tmp, (Protect-Text $json))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-Cn([string]$dn) { if ($dn -match '^CN=([^,]+)') { $matches[1] } else { $dn } }

function Find-Gc([string]$Filter) {
    $s = New-Object System.DirectoryServices.DirectorySearcher
    $s.SearchRoot = [ADSI]"GC://$($script:ForestNc)"
    $s.Filter = $Filter
    $s.PageSize = 200
    [void]$s.PropertiesToLoad.Add('distinguishedName')
    return $s.FindOne()
}

# Self-contained so it runs on a thread job parallel to the AD read. endswith on the
# forest-unique SAM is the only filter this AdminService accepts (others answer 404).
$script:AffinityScript = {
    param($server, $samValue)
    $p = @{
        Uri = "https://$server/AdminService/wmi/SMS_UserMachineRelationship?`$filter=" +
        [uri]::EscapeDataString("endswith(UniqueUserName,'$samValue')") +
        "&`$select=UniqueUserName,ResourceName,ResourceID"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

# Per-device hardware from SCCM inventory, keyed by the affinity ResourceID.
# ResourceID eq is the primary filter shape; the keyed segment is the fallback
# (the string-function filters that 404 on this AdminService are avoided entirely).
$script:HardwareScript = {
    param($server, $pairs)
    function Get-AdminServiceRow([string]$srv, [string]$class, [string]$select, [string]$id, [bool]$useKey) {
        $uri = if ($useKey) { "https://$srv/AdminService/wmi/$class($id)?`$select=$select" }
        else {
            "https://$srv/AdminService/wmi/$class?`$filter=" +
            [uri]::EscapeDataString("ResourceID eq $id") + "&`$select=$select"
        }
        $p = @{ Uri = $uri; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        $r = Invoke-RestMethod @p
        if ($null -ne $r.PSObject.Properties['value']) { return @($r.value) | Select-Object -First 1 }
        return $r
    }
    $useKey = $false
    $results = @()
    foreach ($pair in $pairs) {
        $out = @{ name = [string]$pair.name; manufacturer = ''; model = ''; serial = ''; error = '' }
        if (-not $pair.resourceId) {
            $out.error = 'no ResourceID in the affinity rows'
            $results += $out
            continue
        }
        try {
            $cs = $null
            try {
                $cs = Get-AdminServiceRow $server 'SMS_G_System_COMPUTER_SYSTEM' 'Manufacturer,Model' $pair.resourceId $useKey
            }
            catch {
                # Filter shape rejected: retry once via the keyed segment, keep it for the rest.
                if ($useKey) { throw }
                $useKey = $true
                $cs = Get-AdminServiceRow $server 'SMS_G_System_COMPUTER_SYSTEM' 'Manufacturer,Model' $pair.resourceId $useKey
            }
            if ($cs) {
                $out.manufacturer = [string]$cs.Manufacturer
                $out.model = [string]$cs.Model
            }
            $bios = Get-AdminServiceRow $server 'SMS_G_System_PC_BIOS' 'SerialNumber' $pair.resourceId $useKey
            if ($bios) { $out.serial = [string]$bios.SerialNumber }
        }
        catch { $out.error = $_.Exception.Message }
        $results += $out
    }
    return $results
}

# Sequential partials (partial-<id>-1, -2, ...) the parent streams to the UI.
function Write-LensPartial([hashtable]$Bundle, [string]$ReqId, [int]$Seq) {
    try {
        $path = Join-Path $ExchangeDir ("partial-{0}-{1}.bin" -f $ReqId, $Seq)
        Write-LensBundle $path ($Bundle | ConvertTo-Json -Depth 6)
    }
    catch { }
}

# --- One lookup: the validated pipeline, emitting partials as it goes ---
function Resolve-Lens {
    # "Lens" is singular; the rule misreads the trailing 's'.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    param([string]$identity, [string]$samHint, [string]$server, [string]$reqId)
    $bundle = [ordered]@{
        upn = ''; sam = ''; displayName = ''; email = ''; manager = ''; office = ''
        devices = @(); errors = @()
    }

    # Affinity starts immediately when the SAM is already trustworthy: the finder's
    # hint, a DOMAIN\SAM identity, or a bare SAM. A UPN/display-name waits for AD.
    $samGuess =
    if ($samHint) { $samHint }
    elseif ($identity -match '\\') { $identity.Split('\')[-1] }
    elseif ($identity -notmatch '[@\s]') { $identity }
    else { '' }
    $affinityJob = $null
    if ($samGuess -and $server) {
        try { $affinityJob = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $server, $samGuess } catch { $affinityJob = $null }
    }

    # AD user (forest-wide GC -> home-domain bind).
    $sam = $samGuess
    $uFilter =
    if ($identity -match '@') { "(&(objectClass=user)(userPrincipalName=$identity))" }
    elseif ($identity -match '\s') { "(&(objectClass=user)(displayName=$identity))" }
    else { "(&(objectClass=user)(sAMAccountName=$samGuess))" }
    try {
        $uHit = Find-Gc $uFilter
        if (-not $uHit) { throw "no AD user matched '$identity'." }
        # Binding the DN reaches the user's home domain.
        $user = [ADSI]"LDAP://$([string]$uHit.Properties['distinguishedname'][0])"
        $bundle.sam         = [string]$user.Properties['samaccountname'][0]
        $bundle.displayName = [string]$user.Properties['displayname'][0]
        $bundle.upn         = [string]$user.Properties['userprincipalname'][0]
        $bundle.email       = [string]$user.Properties['mail'][0]
        $mgrDn = [string]$user.Properties['manager'][0]
        if ($mgrDn) { $bundle.manager = Get-Cn $mgrDn }
        # physicalDeliveryOfficeName duplicates the city/province here, so it is only a
        # fallback when the street-address fields are empty.
        $office = @()
        foreach ($k in 'streetaddress', 'l', 'st', 'postalcode') {
            $v = [string]$user.Properties[$k][0]; if ($v) { $office += $v }
        }
        if (-not $office) {
            $v = [string]$user.Properties['physicaldeliveryofficename'][0]; if ($v) { $office += $v }
        }
        $bundle.office = ($office -join ', ')
        if ($bundle.sam) { $sam = $bundle.sam }
    }
    catch {
        $bundle.errors += "AD user: $($_.Exception.Message)"
    }

    # Partial 1: directory facts.
    Write-LensPartial -Bundle $bundle -ReqId $reqId -Seq 1

    # UPN/display-name pick: the SAM only became known from the AD read - start now.
    if (-not $affinityJob -and $sam -and $server) {
        try { $affinityJob = Start-ThreadJob -ScriptBlock $script:AffinityScript -ArgumentList $server, $sam } catch { $affinityJob = $null }
    }

    # SCCM user -> WSID(s): collect the parallel affinity result.
    $wsids = @()
    $wsMap = [ordered]@{}
    if ($sam -and $server) {
        $rows = $null
        try {
            if ($affinityJob) {
                if (Wait-Job -Job $affinityJob -Timeout 45) {
                    $rows = Receive-Job -Job $affinityJob -ErrorAction Stop
                }
                else { throw 'timed out after 45s.' }
            }
            else {
                $rows = & $script:AffinityScript $server $sam
            }
        }
        catch {
            $bundle.errors += "SCCM affinity (SMS_UserMachineRelationship, endswith '$sam'): $($_.Exception.Message)"
        }
        finally {
            if ($affinityJob) { Remove-Job -Job $affinityJob -Force -ErrorAction SilentlyContinue }
        }
        # name -> ResourceID pairs; the id feeds the hardware-inventory query.
        foreach ($row in @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam })) {
            $rn = [string]$row.ResourceName
            if ($rn -and -not $wsMap.Contains($rn)) { $wsMap[$rn] = [string]$row.ResourceID }
        }
        $wsids = @($wsMap.Keys)
    }

    # Partial 2: name-only device rows the moment affinity lands.
    if ($wsids.Count -gt 0) {
        $bundle.devices = @($wsids | ForEach-Object {
                [ordered]@{ name = $_; os = ''; lastLogon = ''; domain = ''
                    model = ''; serial = ''; manufacturer = ''
                    note = 'loading details…'; bitLockerKeys = @()
                }
            })
        Write-LensPartial -Bundle $bundle -ReqId $reqId -Seq 2
    }

    # Hardware runs on a thread job parallel to the per-WSID AD loop below.
    $hwJob = $null
    if ($wsids.Count -gt 0 -and $server) {
        $pairs = @($wsids | ForEach-Object { @{ name = $_; resourceId = [string]$wsMap[$_] } })
        try { $hwJob = Start-ThreadJob -ScriptBlock $script:HardwareScript -ArgumentList $server, $pairs } catch { $hwJob = $null }
    }

    # Per WSID: OS / last-logon / BitLocker, all from the computer's AD object.
    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($wsid in $wsids) {
        $dev = [ordered]@{ name = $wsid; os = ''; lastLogon = ''; domain = ''
            model = ''; serial = ''; manufacturer = ''
            note = ''; bitLockerKeys = @()
        }
        try {
            $cHit = Find-Gc "(&(objectClass=computer)(cn=$wsid))"
            if ($cHit) {
                $compDn = [string]$cHit.Properties['distinguishedname'][0]
                $dev.domain = (($compDn -split ',' |
                            Where-Object { $_ -match '^DC=' } |
                            ForEach-Object { $_.Substring(3) }) -join '.')

                # OS + last domain logon (lastLogonTimestamp: replicated, up to ~14 days
                # coarse - good enough for "which of these machines is current").
                $cs = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
                $cs.SearchScope = 'Base'
                $cs.Filter = '(objectClass=*)'
                'operatingsystem', 'lastlogontimestamp' |
                    ForEach-Object { [void]$cs.PropertiesToLoad.Add($_) }
                $c = $cs.FindOne()
                if ($c) {
                    if ($c.Properties['operatingsystem'].Count -gt 0) {
                        $dev.os = [string]$c.Properties['operatingsystem'][0]
                    }
                    if ($c.Properties['lastlogontimestamp'].Count -gt 0) {
                        $ft = [int64]$c.Properties['lastlogontimestamp'][0]
                        if ($ft -gt 0) { $dev.lastLogon = [datetime]::FromFileTimeUtc($ft).ToString('o') }
                    }
                }

                $bl = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
                $bl.Filter = '(objectClass=msFVE-RecoveryInformation)'
                'msfve-recoverypassword', 'whencreated' |
                    ForEach-Object { [void]$bl.PropertiesToLoad.Add($_) }
                $keys = @($bl.FindAll())
                if ($keys.Count -gt 0) {
                    $dev.bitLockerKeys = @($keys | ForEach-Object {
                            # whenCreated marshals as a DateTime; normalize to ISO8601 UTC so the
                            # DTO contract holds and newest-first selection is chronological.
                            $wc = $_.Properties['whencreated'][0]
                            $iso = ''
                            if ($wc -is [datetime]) {
                                $iso = $wc.ToUniversalTime().ToString('o')
                            }
                            elseif ($wc) {
                                $dt = [datetime]::MinValue
                                if ([datetime]::TryParse([string]$wc, [ref]$dt)) {
                                    $iso = $dt.ToUniversalTime().ToString('o')
                                }
                                else { $iso = [string]$wc }
                            }
                            @{
                                password = [string]$_.Properties['msfve-recoverypassword'][0]
                                created  = $iso
                            }
                        })
                }
                elseif (-not $dev.note) {
                    $dev.note = 'BitLocker not escrowed to AD (or not readable)'
                }
            }
            elseif (-not $dev.note) { $dev.note = 'computer object not found in AD' }
        }
        catch {
            if (-not $dev.note) { $dev.note = "BitLocker: $($_.Exception.Message)" }
        }
        $devices.Add($dev)
    }

    # Merge the parallel hardware results; a failed source degrades to blank fields.
    if ($hwJob) {
        $hwRows = $null
        try {
            if (Wait-Job -Job $hwJob -Timeout 30) { $hwRows = Receive-Job -Job $hwJob -ErrorAction Stop }
            else { throw 'timed out after 30s.' }
        }
        catch { $bundle.errors += "SCCM hardware inventory: $($_.Exception.Message)" }
        finally { Remove-Job -Job $hwJob -Force -ErrorAction SilentlyContinue }

        $hwErrors = @()
        foreach ($row in @($hwRows)) {
            $dev = $devices | Where-Object { $_.name -eq [string]$row.name } | Select-Object -First 1
            if ($null -eq $dev) { continue }
            $dev.manufacturer = [string]$row.manufacturer
            $dev.model = [string]$row.model
            $dev.serial = [string]$row.serial
            if ($row.error) { $hwErrors += "$($row.name): $($row.error)" }
        }
        # One class-wide failure (e.g. a 404 on every device) collapses to a single entry.
        if ($hwErrors.Count -gt 0) {
            $unique = @($hwErrors | ForEach-Object { ($_ -split ': ', 2)[-1] } | Select-Object -Unique)
            if ($unique.Count -eq 1 -and $hwErrors.Count -gt 1) {
                $bundle.errors += "SCCM hardware inventory: $($unique[0])"
            }
            else { $bundle.errors += @($hwErrors | ForEach-Object { "SCCM hardware ($_)" }) }
        }
    }
    $bundle.devices = $devices.ToArray()

    $resultPath = Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)
    Write-LensBundle $resultPath ($bundle | ConvertTo-Json -Depth 6)
}
