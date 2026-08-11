#Requires -Version 5.1
<#
.SYNOPSIS
    Shared helpers for LensAgent.ps1: crypto/exchange I/O and the AD/SCCM lookup
    (Resolve-Lens).

.DESCRIPTION
    Dot-sourced by LensAgent.ps1 in the agent's main runspace, and by each lookup
    ThreadJob the serve loop spawns (a slow lookup runs off the loop so the loop stays
    free for the next request). Also dot-sourced by LensLookupWorker.ps1 when DONUT runs
    de-elevated and is already the interactive user, which calls Resolve-Lens directly.

    Callers must set these script-scope variables before use:
      $script:ForestNc   the forest root naming context (for GC binds)
      $script:KeyIv      48-byte AES key+IV (from key.bin); exchange callers only
      $ExchangeDir       the ACL-locked exchange directory; exchange callers only

    Resolve-Lens returns the bundle JSON. Without $reqId and $ExchangeDir it only
    returns it, writing no partials and no result file.

    Resolve-MachineOwnerBatch runs the affinity query the other way (machine -> primary user).
    Unlike the person direction, which must use endswith because a UniqueUserName carries
    a domain backslash, a plain "ResourceName eq '<wsid>'" filter is served - confirmed
    against the site this ships to. SCCM answers with an account name; SMS_R_User's
    FullUserName (User Discovery's copy of displayName) then names the person. SCCM first
    because it aggregates users from EVERY forest the site covers, while Find-Gc reads the
    agent's own forest's GC and can never name a sibling-forest user - which is exactly how
    owner chips shipped showing SAMs. The GC stays as the fallback for its one forest, and
    the SAM stands in when both reads fail. Names memoize per batch (OwnerNameCache
    lives in the request job's runspace).

    It takes the WHOLE list in one request and resolves it serially, deliberately. N
    separate requests would cost N files, N AES round trips and N parent polls, while
    holding N of the three interactive runspaces. The agent runs the whole batch on one
    ThreadJob off its serve loop, so a slow batch never delays a person lookup.

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
    # An unreachable DC hangs a searcher indefinitely without this cap.
    $s.ClientTimeout = [TimeSpan]::FromSeconds(15)
    # No PageSize: it only enables paging, and every caller here takes FindOne.
    [void]$s.PropertiesToLoad.Add('distinguishedName')
    return $s.FindOne()
}

# endswith on the forest-unique SAM is the only filter this AdminService serves.
$script:AffinityScript = {
    param($server, $samValue)
    $p = @{
        Uri = "https://$server/AdminService/wmi/SMS_UserMachineRelationship?`$filter=" +
        [uri]::EscapeDataString("endswith(UniqueUserName,'$samValue')") +
        "&`$select=UniqueUserName,ResourceName,ResourceID"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

# ResourceID eq N with a keyed-segment fallback, since string filters 404 here.
$script:HardwareScript = {
    param($server, $pairs)
    function Get-AdminServiceRow([string]$srv, [string]$class, [string]$select, [string]$id, [bool]$useKey) {
        # The braces are load-bearing: "$class?" parses as an undefined variable class?.
        $uri = if ($useKey) { "https://$srv/AdminService/wmi/$class($id)?`$select=$select" }
        else {
            "https://$srv/AdminService/wmi/${class}?`$filter=" +
            [uri]::EscapeDataString("ResourceID eq $id") + "&`$select=$select"
        }
        $p = @{ Uri = $uri; UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15 }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        $r = Invoke-RestMethod @p
        if ($null -ne $r.PSObject.Properties['value']) { return @($r.value) | Select-Object -First 1 }
        return $r
    }
    # A site that will not serve the filter shape says so two ways: it 404s, or it answers
    # 200 with an empty set. Both mean "use the keyed segment", and the choice then sticks.
    function Get-InventoryRow([string]$srv, [string]$class, [string]$select, [string]$id) {
        if (-not $script:UseKey) {
            try {
                $row = Get-AdminServiceRow -srv $srv -class $class -select $select -id $id -useKey $false
                if ($row) { return $row }
            }
            catch { $script:FilterError = $_.Exception.Message }
            $script:UseKey = $true
        }
        return Get-AdminServiceRow -srv $srv -class $class -select $select -id $id -useKey $true
    }
    $script:UseKey = $false
    $script:FilterError = ''
    $results = @()
    foreach ($pair in $pairs) {
        $out = @{ name = [string]$pair.name; manufacturer = ''; model = ''; serial = ''; error = '' }
        if (-not $pair.resourceId) {
            $out.error = 'no ResourceID in the affinity rows'
            $results += $out
            continue
        }
        try {
            $cs = Get-InventoryRow -srv $server -class 'SMS_G_System_COMPUTER_SYSTEM' `
                -select 'Manufacturer,Model' -id $pair.resourceId
            if ($cs) {
                $out.manufacturer = [string]$cs.Manufacturer
                $out.model = [string]$cs.Model
            }
            $bios = Get-InventoryRow -srv $server -class 'SMS_G_System_PC_BIOS' `
                -select 'SerialNumber' -id $pair.resourceId
            if ($bios) { $out.serial = [string]$bios.SerialNumber }
            # Both shapes answering nothing used to blank the card with no reason on it.
            if (-not $out.model -and -not $out.serial) {
                $out.error = "no inventory rows for ResourceID $($pair.resourceId)"
                if ($script:FilterError) { $out.error += " (filter form: $($script:FilterError))" }
            }
        }
        catch { $out.error = $_.Exception.Message }
        $results += $out
    }
    return $results
}

# Sequential partials (partial-<id>-1, -2, ...) the parent streams to the UI.
function Write-LensPartial([hashtable]$Bundle, [string]$ReqId, [int]$Seq) {
    # No exchange means an in-process caller, which gets the whole bundle at the end.
    if (-not $ReqId -or -not $ExchangeDir) { return }
    try {
        $path = Join-Path $ExchangeDir ("partial-{0}-{1}.bin" -f $ReqId, $Seq)
        Write-LensBundle $path ($Bundle | ConvertTo-Json -Depth 6)
    }
    catch {
        Write-Verbose "Lens partial $Seq not written: $($_.Exception.Message)"
    }
}

# The forest root naming context every GC bind hangs off. Its own function so a caller
# that is a PowerShell class never names [ADSI], which does not resolve off Windows.
function Get-LensForestNc {
    return [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0]
}

# Machine to primary user, where a plain 'ResourceName eq' filter is served. See .NOTES.
$script:OwnerScript = {
    param($server, $wsid)
    $uri = "https://$server/AdminService/wmi/SMS_UserMachineRelationship?`$filter=" +
    [uri]::EscapeDataString("ResourceName eq '$wsid'") + "&`$select=UniqueUserName,ResourceName"
    $p = @{ Uri = $uri; UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15 }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

# A name does not change mid-batch, so memoize it for this runspace's lifetime.
$script:OwnerNameCache = @{}

# UniqueUserName to display name. SCCM first: SMS_R_User.FullUserName covers every
# forest the site covers, which the GC cannot. See .NOTES.
function Get-OwnerDisplayName {
    param([string]$uniqueUserName, [string]$sam, [string]$server)
    $r = [ordered]@{ owner = ''; error = '' }
    if ($script:OwnerNameCache.ContainsKey($uniqueUserName)) {
        $r.owner = [string]$script:OwnerNameCache[$uniqueUserName]
        return $r
    }
    try {
        # endswith, not eq: the only operator this AdminService serves on this attribute.
        $uri = "https://$server/AdminService/wmi/SMS_R_User?`$filter=" +
        [uri]::EscapeDataString("endswith(UniqueUserName,'$uniqueUserName')") +
        "&`$select=FullUserName,UniqueUserName"
        $p = @{ Uri = $uri; UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15 }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        $rows = @((Invoke-RestMethod @p).value)
        if ($rows.Count -gt 0) { $r.owner = [string]$rows[0].FullUserName }
    }
    catch { $r.error = "SCCM user: $($_.Exception.Message)" }
    if (-not $r.owner) {
        # The GC covers only the agent's own forest, never a sibling forest's user.
        try {
            $hit = Find-Gc "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$sam))"
            if ($hit) {
                $user = [ADSI]"LDAP://$([string]$hit.Properties['distinguishedname'][0])"
                $r.owner = [string]$user.Properties['displayname'][0]
            }
        }
        catch { $r.error = "AD user: $($_.Exception.Message)" }
    }
    # Only a found name is memoized, so a transient failure retries on the next batch.
    if ($r.owner) { $script:OwnerNameCache[$uniqueUserName] = $r.owner }
    return $r
}

# One machine to "who normally uses it". SCCM affinity names the account, then
# Get-OwnerDisplayName names the person, with the SAM as the fallback.
function Get-MachineOwner {
    param([string]$wsid, [string]$server)
    $out = [ordered]@{ name = $wsid; owner = ''; sam = ''; error = '' }
    if (-not $wsid) { $out.error = 'no machine name'; return $out }
    $unique = ''
    try {
        $rows = @(& $script:OwnerScript $server $wsid)
        if ($rows.Count -eq 0) {
            $out.error = "no primary user recorded for $wsid"
            return $out
        }
        # Affinity can list several, and the first is SCCM's own ordering, as in the Lens.
        $unique = [string]$rows[0].UniqueUserName
        $out.sam = ($unique -split '\\')[-1]
    }
    catch {
        $out.error = "SCCM affinity: $($_.Exception.Message)"
        return $out
    }
    $named = Get-OwnerDisplayName -uniqueUserName $unique -sam $out.sam -server $server
    $out.owner = [string]$named.owner
    if ($named.error) { $out.error = [string]$named.error }
    # A SAM still tells them apart when the naming is what failed.
    if (-not $out.owner) { $out.owner = $out.sam }
    return $out
}

# The whole machine list in one request. See .NOTES for why it is not fanned out.
function Resolve-MachineOwnerBatch {
    param([string[]]$wsids, [string]$server)
    $bundle = [ordered]@{ owners = @(); error = '' }
    if (-not $server) {
        $bundle.error = 'no AdminService host configured'
        return ($bundle | ConvertTo-Json -Compress -Depth 4)
    }
    $rows = foreach ($wsid in @($wsids | Where-Object { $_ })) { Get-MachineOwner -wsid $wsid -server $server }
    $bundle.owners = @($rows)
    return ($bundle | ConvertTo-Json -Compress -Depth 4)
}

# --- One lookup: the validated pipeline, emitting partials as it goes ---
function Resolve-Lens {
    # "Lens" is singular, and the rule misreads the trailing 's'.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '')]
    param([string]$identity, [string]$samHint, [string]$server, [string]$reqId)
    $bundle = [ordered]@{
        upn = ''; sam = ''; displayName = ''; email = ''; manager = ''; office = ''
        devices = @(); errors = @()
    }

    # Affinity can start early only when the SAM is already trustworthy.
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
    # objectClass=user alone also matches computers, which derive from it.
    if ($identity -match '@') { "(&(objectCategory=person)(objectClass=user)(userPrincipalName=$identity))" }
    elseif ($identity -match '\s') { "(&(objectCategory=person)(objectClass=user)(displayName=$identity))" }
    else { "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$samGuess))" }
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
        # physicalDeliveryOfficeName duplicates the city and province here.
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

    # On a UPN or display-name pick, the SAM only became known from the AD read.
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
        # name -> ResourceID pairs, where the id feeds the hardware-inventory query.
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
    $hwPairs = @()
    if ($wsids.Count -gt 0 -and $server) {
        $hwPairs = @($wsids | ForEach-Object { @{ name = $_; resourceId = [string]$wsMap[$_] } })
        try { $hwJob = Start-ThreadJob -ScriptBlock $script:HardwareScript -ArgumentList $server, $hwPairs } catch { $hwJob = $null }
    }

    # Per WSID: OS / last-logon / BitLocker, all from the computer's AD object.
    $devices = [System.Collections.Generic.List[object]]::new()
    foreach ($wsid in $wsids) {
        $dev = [ordered]@{ name = $wsid; os = ''; lastLogon = ''; domain = ''
            model = ''; serial = ''; manufacturer = ''
            note = ''; bitLockerKeys = @()
        }
        try {
            $cHit = Find-Gc "(&(objectCategory=computer)(cn=$wsid))"
            if ($cHit) {
                $compDn = [string]$cHit.Properties['distinguishedname'][0]
                $dev.domain = (($compDn -split ',' |
                            Where-Object { $_ -match '^DC=' } |
                            ForEach-Object { $_.Substring(3) }) -join '.')

                # lastLogonTimestamp is replicated, so it can be up to 14 days coarse.
                $cs = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$compDn")
                $cs.SearchScope = 'Base'
                $cs.Filter = '(objectClass=*)'
                $cs.ClientTimeout = [TimeSpan]::FromSeconds(15)
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
                $bl.ClientTimeout = [TimeSpan]::FromSeconds(15)
                'msfve-recoverypassword', 'whencreated' |
                    ForEach-Object { [void]$bl.PropertiesToLoad.Add($_) }
                $keys = @($bl.FindAll())
                if ($keys.Count -gt 0) {
                    $dev.bitLockerKeys = @($keys | ForEach-Object {
                            # ISO8601 UTC keeps the DTO contract and newest-first order.
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

    # Merges the parallel hardware results, where a failed source degrades to blanks.
    if ($hwPairs.Count -gt 0) {
        $hwRows = $null
        try {
            if ($hwJob) {
                if (Wait-Job -Job $hwJob -Timeout 30) { $hwRows = Receive-Job -Job $hwJob -ErrorAction Stop }
                else { throw 'timed out after 30s.' }
            }
            # No job means it would not start, and inline keeps the cards filled.
            else { $hwRows = & $script:HardwareScript $server $hwPairs }
        }
        catch { $bundle.errors += "SCCM hardware inventory: $($_.Exception.Message)" }
        finally { if ($hwJob) { Remove-Job -Job $hwJob -Force -ErrorAction SilentlyContinue } }

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

    $json = $bundle | ConvertTo-Json -Depth 6
    # Only the agent has an exchange to write to. A de-elevated DONUT takes the return.
    if ($reqId -and $ExchangeDir) {
        Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $json
    }
    return $json
}
