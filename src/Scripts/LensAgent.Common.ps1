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

    Resolve-UserSoftware walks the user direction (user -> application installs):
    SMS_R_User names the ResourceIDs (endswith, exact tail client side),
    SMS_FullCollectionMembership the collections, then one $select-trimmed
    SMS_DeploymentSummary fetch is filtered client side - an or-filter over the
    collections 404s on this route. Install-intent applications and every package
    deployment make the list, packages carrying their program name so an operator
    can tell software from maintenance. It rides its own request kind, dispatched
    in parallel with the person lookup, so neither ever waits on the other.

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
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = @{ name = [string]$pair.name; manufacturer = ''; model = ''; serial = ''; error = '' }
        if (-not $pair.resourceId) {
            $out.error = 'no ResourceID in the affinity rows'
            $out.ms = $sw.ElapsedMilliseconds
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
        $out.ms = $sw.ElapsedMilliseconds
        $results += $out
    }
    return $results
}

# One device's AD detail, self contained: nested jobs do not inherit Common's functions.
$script:DeviceScript = {
    param($forestNc, $wsid)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dev = [ordered]@{ name = $wsid; os = ''; lastLogon = ''; domain = ''
        model = ''; serial = ''; manufacturer = ''
        note = ''; bitLockerKeys = @()
    }
    try {
        $gc = New-Object System.DirectoryServices.DirectorySearcher
        $gc.SearchRoot = [ADSI]"GC://$forestNc"
        $gc.Filter = "(&(objectCategory=computer)(cn=$wsid))"
        $gc.ClientTimeout = [TimeSpan]::FromSeconds(15)
        [void]$gc.PropertiesToLoad.Add('distinguishedName')
        $cHit = $gc.FindOne()
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
    $dev.ms = $sw.ElapsedMilliseconds
    return $dev
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

# User to application installs: ResourceIDs, collection memberships, one summary fetch.
$script:SoftwareScript = {
    param($server, $sam)
    function Invoke-SoftwareQuery([string]$srv, [string]$query) {
        $p = @{ Uri = "https://$srv/AdminService/wmi/$query"
            UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15
        }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        return @((Invoke-RestMethod @p).value)
    }
    # endswith keeps the domain backslash out of the URL, and the exact tail match is ours.
    $users = Invoke-SoftwareQuery $server ("SMS_R_User?`$filter=" +
        [uri]::EscapeDataString("endswith(UniqueUserName,'$sam')") +
        "&`$select=ResourceID,UniqueUserName")
    $ids = @($users | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $sam } |
            ForEach-Object { [string]$_.ResourceID })
    if ($ids.Count -eq 0) { return @() }
    # ponytail: no keyed fallback here, so a 200-empty rejection reads as no collections.
    $collections = [System.Collections.Generic.HashSet[string]]::new()
    foreach ($id in $ids) {
        $rows = Invoke-SoftwareQuery $server ("SMS_FullCollectionMembership?`$filter=" +
            [uri]::EscapeDataString("ResourceID eq $id") + "&`$select=CollectionID")
        foreach ($r in $rows) { [void]$collections.Add([string]$r.CollectionID) }
    }
    if ($collections.Count -eq 0) { return @() }
    # One site-wide fetch beats a query per collection, and or-filters 404 on this route.
    $sum = Invoke-SoftwareQuery $server ("SMS_DeploymentSummary?`$select=" +
        'SoftwareName,CollectionName,CollectionID,FeatureType,DesiredConfigType,ProgramName')
    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $rows = foreach ($d in $sum) {
        # Applications count when the intent is install, packages whatever their program.
        $ft = [int]$d.FeatureType
        if ($ft -ne 1 -and $ft -ne 2) { continue }
        if ($ft -eq 1 -and [int]$d.DesiredConfigType -ne 1) { continue }
        if (-not $collections.Contains([string]$d.CollectionID)) { continue }
        # The program rides package rows, since no generic filter can sort those apart.
        $prog = if ($ft -eq 2) { [string]$d.ProgramName } else { '' }
        if (-not $seen.Add("$($d.SoftwareName)|$($d.CollectionName)|$prog")) { continue }
        @{ software = [string]$d.SoftwareName; collection = [string]$d.CollectionName
            program = $prog
        }
    }
    return @($rows | Sort-Object { $_.software })
}

# The user's whole software list in one request, mirroring the owner batch shape.
function Resolve-UserSoftware {
    param([string]$identity, [string]$sam, [string]$server)
    $bundle = [ordered]@{ deployments = @(); error = '' }
    if (-not $server) {
        $bundle.error = 'no AdminService host configured'
        return ($bundle | ConvertTo-Json -Compress -Depth 4)
    }
    try {
        $resolved = $sam
        if (-not $resolved) {
            # A UPN or display name pick carries no SAM, so one GC read supplies it.
            if ($identity -match '\\') { $resolved = $identity.Split('\')[-1] }
            elseif ($identity -notmatch '[@\s]') { $resolved = $identity }
            else {
                $uFilter =
                if ($identity -match '@') {
                    "(&(objectCategory=person)(objectClass=user)(userPrincipalName=$identity))"
                }
                else { "(&(objectCategory=person)(objectClass=user)(displayName=$identity))" }
                $hit = Find-Gc $uFilter
                if ($hit) {
                    $user = [ADSI]"LDAP://$([string]$hit.Properties['distinguishedname'][0])"
                    $resolved = [string]$user.Properties['samaccountname'][0]
                }
            }
        }
        if (-not $resolved) { throw "no SAM resolved for '$identity'." }
        $bundle.deployments = @(& $script:SoftwareScript $server $resolved)
    }
    catch { $bundle.error = "SCCM software: $($_.Exception.Message)" }
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
    # Cumulative stage marks ride the bundle, so debug logging can split the gather.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $marks = [ordered]@{}

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
    $marks.user = $sw.ElapsedMilliseconds

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
    $marks.affinity = $sw.ElapsedMilliseconds

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

    # One hardware job per device, beside the AD loop: the provider is slow per call,
    # so serial pairs were the whole lookup's tail.
    $hwJobs = [System.Collections.Generic.List[hashtable]]::new()
    $hwPairs = @()
    if ($wsids.Count -gt 0 -and $server) {
        $hwPairs = @($wsids | ForEach-Object { @{ name = $_; resourceId = [string]$wsMap[$_] } })
        foreach ($hwPair in $hwPairs) {
            $hwJob = $null
            try {
                $hwJob = Start-ThreadJob -ScriptBlock $script:HardwareScript `
                    -ArgumentList $server, @($hwPair)
            }
            catch { $hwJob = $null }
            $hwJobs.Add(@{ Job = $hwJob; Pair = $hwPair })
        }
    }

    # Per WSID: OS / last-logon / BitLocker, one job per device beside the hardware jobs.
    # ponytail: 2N nested jobs can outgrow the throttle, and overflow queues in this lane only.
    $devJobs = [System.Collections.Generic.List[hashtable]]::new()
    foreach ($wsid in $wsids) {
        $devJob = $null
        try {
            $devJob = Start-ThreadJob -ScriptBlock $script:DeviceScript `
                -ArgumentList $script:ForestNc, $wsid
        }
        catch { $devJob = $null }
        $devJobs.Add(@{ Job = $devJob; Wsid = $wsid })
    }

    $devices = [System.Collections.Generic.List[object]]::new()
    $devDeadline = [datetime]::UtcNow.AddSeconds(30)
    foreach ($entry in $devJobs) {
        $dev = $null
        try {
            if ($entry.Job) {
                $left = [int][Math]::Max(1, ($devDeadline - [datetime]::UtcNow).TotalSeconds)
                if (Wait-Job -Job $entry.Job -Timeout $left) {
                    $dev = @(Receive-Job -Job $entry.Job -ErrorAction Stop) | Select-Object -Last 1
                }
                else { throw 'timed out after 30s.' }
            }
            # No job means it would not start, and inline keeps the row filled.
            else { $dev = & $script:DeviceScript $script:ForestNc $entry.Wsid }
        }
        catch {
            $dev = [ordered]@{ name = $entry.Wsid; os = ''; lastLogon = ''; domain = ''
                model = ''; serial = ''; manufacturer = ''
                note = "AD detail: $($_.Exception.Message)"; bitLockerKeys = @()
            }
        }
        finally {
            if ($entry.Job) { Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue }
        }
        # Each device's AD wall time joins the stage marks, then leaves the bundle row.
        if ($null -ne $dev.ms) {
            $marks["ad $($entry.Wsid)"] = [long]$dev.ms
            $dev.Remove('ms')
        }
        $devices.Add($dev)
    }
    $marks.devices = $sw.ElapsedMilliseconds

    # Merges the parallel hardware results, where a failed source degrades to blanks.
    if ($hwPairs.Count -gt 0) {
        $hwRows = [System.Collections.Generic.List[object]]::new()
        # One shared deadline: the jobs run side by side, so they never earn 30s each.
        $hwDeadline = [datetime]::UtcNow.AddSeconds(30)
        foreach ($entry in $hwJobs) {
            try {
                if ($entry.Job) {
                    $left = [int][Math]::Max(1, ($hwDeadline - [datetime]::UtcNow).TotalSeconds)
                    if (Wait-Job -Job $entry.Job -Timeout $left) {
                        $got = @(Receive-Job -Job $entry.Job -ErrorAction Stop)
                        foreach ($r in $got) { $hwRows.Add($r) }
                    }
                    else { throw 'timed out after 30s.' }
                }
                # No job means it would not start, and inline keeps the cards filled.
                else {
                    $got = @(& $script:HardwareScript $server @($entry.Pair))
                    foreach ($r in $got) { $hwRows.Add($r) }
                }
            }
            catch {
                $bundle.errors += "SCCM hardware ($($entry.Pair.name)): $($_.Exception.Message)"
            }
            finally {
                if ($entry.Job) { Remove-Job -Job $entry.Job -Force -ErrorAction SilentlyContinue }
            }
        }

        $hwErrors = @()
        foreach ($row in @($hwRows)) {
            # Each device's provider wall time rides the stage marks for the debug line.
            if ($null -ne $row.ms) { $marks["hw $($row.name)"] = [long]$row.ms }
            $dev = $devices | Where-Object { $_.name -eq [string]$row.name } | Select-Object -First 1
            if ($null -eq $dev) { continue }
            $dev.manufacturer = [string]$row.manufacturer
            $dev.model = [string]$row.model
            $dev.serial = [string]$row.serial
            # A virtual machine does not escrow to AD, so the missing key note is noise there.
            if ($dev.model -match 'virtual' -and $dev.note -like 'BitLocker not escrowed*') {
                $dev.note = ''
            }
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
    $marks.hardware = $sw.ElapsedMilliseconds
    $bundle.timings = $marks

    $json = $bundle | ConvertTo-Json -Depth 6
    # Only the agent has an exchange to write to. A de-elevated DONUT takes the return.
    if ($reqId -and $ExchangeDir) {
        Write-LensBundle (Join-Path $ExchangeDir ("result-{0}.bin" -f $reqId)) $json
    }
    return $json
}
