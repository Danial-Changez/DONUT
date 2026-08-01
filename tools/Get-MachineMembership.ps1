#Requires -Version 5.1
<#
.SYNOPSIS
    Shows a machine's (and optionally a user's) AD group memberships and SCCM collection
    memberships, reporting which query shapes this site actually serves.

.DESCRIPTION
    The probe for DONUT's planned "Member Of" popup. It answers, from one run as a normal
    domain user, everything the feature cannot be designed without:

      - Which forest holds the machine/user, and their DIRECT AD groups (memberOf, every
        value). The primary group is printed separately: primaryGroupID is not in memberOf,
        and the popup omitting it should be a decision made on sight, not an accident.
      - With -Nested, the transitive expansion via LDAP_MATCHING_RULE_IN_CHAIN, timed -
        the number that decides whether the popup can ever offer "include nested".
      - The SCCM chain: identity -> ResourceID -> SMS_FullCollectionMembership ->
        collection names. This AdminService serves only some filter shapes (numeric eq
        and endswith are proven; string eq has 404'd elsewhere), so EVERY step prints the
        shape it tried and whether the site served it. Those verdicts are what the real
        implementation gets built from.

    An empty SCCM section with served shapes means RBAC hides those collections from this
    account - a different fact from a 404, and the output tells them apart.

.PARAMETER Name
    The machine (WSID) to look up.

.PARAMETER User
    Optional user (sAMAccountName or UPN) - validates the person direction in the same run.

.PARAMETER Nested
    Also run the transitive group expansion for each found identity, timed separately.

.PARAMETER Domains
    Forests to search. Defaults to the 'domains' key in DONUT's config.json.

.PARAMETER SiteServer
    AdminService host. Defaults to the 'adminServiceHost' key in DONUT's config.json.

.NOTES
    Run as a NORMAL domain user, not elevated: SCCM collection visibility is RBAC-scoped
    per account, and DONUT's SCCM calls run de-elevated as the console user - an elevated
    run would validate the wrong identity's view.

    Prints directory and SCCM data to the console only; writes nothing to disk.

.EXAMPLE
    pwsh -File tools\Get-MachineMembership.ps1 -Name CAP-1024

.EXAMPLE
    pwsh -File tools\Get-MachineMembership.ps1 -Name CAP-1024 -User asmith -Nested
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Name,
    [string] $User,
    [switch] $Nested,
    [string[]] $Domains,
    [string] $SiteServer
)

Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

# --- Config fallbacks (same source the app reads) ---------------------------------------
if (-not $Domains -or -not $SiteServer) {
    $configPath = Join-Path $env:ProgramData 'DONUT\data\config\config.json'
    if (Test-Path -LiteralPath $configPath) {
        try {
            $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
            if (-not $Domains) { $Domains = @($cfg.domains) }
            if (-not $SiteServer) { $SiteServer = [string]$cfg.adminServiceHost }
        }
        catch { Write-Host "Could not read $configPath : $($_.Exception.Message)" -ForegroundColor Red }
    }
}
if (-not $Domains) { Write-Host 'No forests to query (no -Domains and no config).' -ForegroundColor Red; return }

# --- Small helpers ----------------------------------------------------------------------

# First RDN of a DN, unescaped - "CN=VPN\, Staff,OU=..." -> "VPN, Staff".
function Get-CnFromDn([string]$dn) {
    if ($dn -match '^CN=((?:\\.|[^,])+)') { return ($Matches[1] -replace '\\(.)', '$1') }
    return $dn
}

# One timed LDAP read against one forest; returns the first hit with EVERY value of the
# requested properties (the finder's row shape keeps [0] only, which loses memberOf).
function Find-DirectoryEntry {
    param([string]$domain, [string]$filter, [string[]]$props)
    $entry = $null
    $searcher = $null
    try {
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry)
        $searcher.Filter = $filter
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds(10)
        foreach ($p in $props) { [void]$searcher.PropertiesToLoad.Add($p) }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $hit = $searcher.FindOne()
        $sw.Stop()
        if ($null -eq $hit) { return @{ Found = $false; Ms = $sw.ElapsedMilliseconds } }
        $bag = @{}
        foreach ($p in $props) {
            if ($hit.Properties.Contains($p)) { $bag[$p] = @($hit.Properties[$p]) }
        }
        return @{ Found = $true; Ms = $sw.ElapsedMilliseconds; Props = $bag }
    }
    catch { return @{ Found = $false; Error = $_.Exception.Message } }
    finally {
        if ($searcher) { $searcher.Dispose() }
        if ($entry) { $entry.Dispose() }
    }
}

# The primary group is objectSid with its RID swapped for primaryGroupID; memberOf never
# lists it, so it must be resolved (and shown) explicitly.
function Resolve-PrimaryGroup {
    param([string]$domain, [byte[]]$objectSid, [int]$primaryGroupId)
    try {
        $sid = [byte[]]$objectSid.Clone()
        $rid = [BitConverter]::GetBytes([uint32]$primaryGroupId)
        [Array]::Copy($rid, 0, $sid, $sid.Length - 4, 4)
        $hex = ($sid | ForEach-Object { '\{0:x2}' -f $_ }) -join ''
        $r = Find-DirectoryEntry -domain $domain -filter "(objectSid=$hex)" -props @('distinguishedName')
        if ($r.Found) { return [string]$r.Props['distinguishedName'][0] }
    }
    catch { return "could not resolve: $($_.Exception.Message)" }
    return ''
}

# Sweeps the forests for one identity and prints its whole AD story.
function Show-AdMembership {
    param([string]$label, [string]$filter)
    Write-Host ''
    Write-Host "=== AD: $label ===" -ForegroundColor Cyan
    $homeForest = ''
    foreach ($domain in $Domains) {
        $r = Find-DirectoryEntry -domain $domain -filter $filter -props @(
            'distinguishedName', 'memberOf', 'primaryGroupID', 'objectSid')
        if ($r.Error) { Write-Host "  $domain : FAILED - $($r.Error)" -ForegroundColor Yellow; continue }
        if (-not $r.Found) { Write-Host "  $domain : no match ($($r.Ms)ms)"; continue }

        $homeForest = $domain
        $dn = [string]$r.Props['distinguishedName'][0]
        $groups = @($r.Props['memberOf'] | ForEach-Object { [string]$_ } | Sort-Object)
        Write-Host "  $domain : FOUND in $($r.Ms)ms" -ForegroundColor Green
        Write-Host "  DN: $dn"
        Write-Host "  Direct groups ($($groups.Count)):"
        foreach ($g in $groups) { Write-Host ("    {0,-40} {1}" -f (Get-CnFromDn $g), $g) }

        if ($r.Props.ContainsKey('primaryGroupID') -and $r.Props.ContainsKey('objectSid')) {
            $pg = Resolve-PrimaryGroup -domain $domain -objectSid ([byte[]]$r.Props['objectSid'][0]) `
                -primaryGroupId ([int]$r.Props['primaryGroupID'][0])
            if ($pg) { Write-Host "  Primary group (not in memberOf): $(Get-CnFromDn $pg)" -ForegroundColor DarkGray }
        }

        if ($Nested) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
            $s = [System.DirectoryServices.DirectorySearcher]::new($entry)
            try {
                $s.Filter = "(&(objectCategory=group)(member:1.2.840.113556.1.4.1941:=$dn))"
                $s.PageSize = 500   # transitive sets can be big; here completeness beats the cap
                [void]$s.PropertiesToLoad.Add('distinguishedName')
                $all = $s.FindAll()
                try { $count = @($all).Count } finally { $all.Dispose() }
                $sw.Stop()
                Write-Host "  Nested (transitive) groups: $count in $($sw.ElapsedMilliseconds)ms" -ForegroundColor Magenta
            }
            catch { Write-Host "  Nested expansion FAILED: $($_.Exception.Message)" -ForegroundColor Yellow }
            finally { $s.Dispose(); $entry.Dispose() }
        }
        break   # an account lives in one forest; the rest reported "no match" above or are skipped
    }
    if (-not $homeForest) { Write-Host "  Not found in any forest." -ForegroundColor Yellow }
    return $homeForest
}

# --- SCCM side --------------------------------------------------------------------------

# One AdminService GET with a per-shape verdict: OK / 404 (shape not served) / error.
function Invoke-AdminServiceProbe {
    param([string]$label, [string]$uri)
    $p = @{ Uri = $uri; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $res = Invoke-RestMethod @p
        $sw.Stop()
        $rows = if ($null -ne $res.PSObject.Properties['value']) { @($res.value) } else { @($res) }
        Write-Host "  [OK   $($sw.ElapsedMilliseconds)ms] $label -> $($rows.Count) row(s)" -ForegroundColor Green
        return @{ Ok = $true; Rows = $rows }
    }
    catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        $shape = if ($msg -match '404') { '404 - shape not served' } else { $msg }
        Write-Host "  [FAIL $($sw.ElapsedMilliseconds)ms] $label -> $shape" -ForegroundColor Yellow
        return @{ Ok = $false }
    }
}

function Show-SccmMembership {
    param([string]$label, [long]$resourceId)
    Write-Host "  Collections for $label (ResourceID $resourceId):" -ForegroundColor Cyan
    $m = Invoke-AdminServiceProbe -label "SMS_FullCollectionMembership ResourceID eq $resourceId" `
        -uri ("https://$SiteServer/AdminService/wmi/SMS_FullCollectionMembership?`$filter=" +
        [uri]::EscapeDataString("ResourceID eq $resourceId") + "&`$select=CollectionID")
    if (-not $m.Ok) { return }
    $ids = @($m.Rows | ForEach-Object { [string]$_.CollectionID } | Sort-Object -Unique)
    if ($ids.Count -eq 0) {
        Write-Host '  0 collections. With a served shape this usually means RBAC hides them from this account.' -ForegroundColor Yellow
        return
    }
    # Names: keyed access first (proven pattern); the string filter tried once for the record.
    $eqTried = $false
    foreach ($id in $ids) {
        $k = Invoke-AdminServiceProbe -label "SMS_Collection('$id') keyed" `
            -uri "https://$SiteServer/AdminService/wmi/SMS_Collection('$id')?`$select=Name,CollectionID"
        $shown = if ($k.Ok -and $k.Rows.Count -gt 0) { [string]$k.Rows[0].Name } else { '(name unavailable)' }
        Write-Host ("    {0,-12} {1}" -f $id, $shown)
        if (-not $eqTried) {
            $eqTried = $true
            [void](Invoke-AdminServiceProbe -label "SMS_Collection CollectionID eq '$id' (string filter, for the record)" `
                    -uri ("https://$SiteServer/AdminService/wmi/SMS_Collection?`$filter=" +
                    [uri]::EscapeDataString("CollectionID eq '$id'") + "&`$select=Name"))
        }
    }
}

# --- Run: AD ----------------------------------------------------------------------------
Write-Host "Forests: $($Domains -join ', ')"
Write-Host "Site   : $(if ($SiteServer) { $SiteServer } else { '(none - SCCM section skipped)' })"

[void](Show-AdMembership -label "computer $Name" `
        -filter "(&(objectCategory=computer)(sAMAccountName=$Name`$))")

if ($User) {
    $userFilter = if ($User.Contains('@')) { "(userPrincipalName=$User)" } else { "(sAMAccountName=$User)" }
    [void](Show-AdMembership -label "user $User" `
            -filter "(&(objectCategory=person)(objectClass=user)$userFilter)")
}

# --- Run: SCCM --------------------------------------------------------------------------
if ($SiteServer) {
    Write-Host ''
    Write-Host '=== SCCM ===' -ForegroundColor Cyan

    $dev = Invoke-AdminServiceProbe -label "SMS_R_System Name eq '$Name' (string filter)" `
        -uri ("https://$SiteServer/AdminService/wmi/SMS_R_System?`$filter=" +
        [uri]::EscapeDataString("Name eq '$Name'") + "&`$select=ResourceID,Name")
    if (-not $dev.Ok -or @($dev.Rows).Count -eq 0) {
        $dev = Invoke-AdminServiceProbe -label "SMS_R_System endswith(Name,'$Name') (fallback shape)" `
            -uri ("https://$SiteServer/AdminService/wmi/SMS_R_System?`$filter=" +
            [uri]::EscapeDataString("endswith(Name,'$Name')") + "&`$select=ResourceID,Name")
    }
    if ($dev.Ok -and @($dev.Rows).Count -gt 0) {
        Show-SccmMembership -label "device $Name" -resourceId ([long]$dev.Rows[0].ResourceID)
    }
    else { Write-Host "  Device $Name not resolvable over AdminService with either shape." -ForegroundColor Yellow }

    if ($User) {
        $u = Invoke-AdminServiceProbe -label "SMS_R_User endswith(UniqueUserName,'$User') (proven shape)" `
            -uri ("https://$SiteServer/AdminService/wmi/SMS_R_User?`$filter=" +
            [uri]::EscapeDataString("endswith(UniqueUserName,'$User')") + "&`$select=ResourceID,UniqueUserName")
        if ($u.Ok -and @($u.Rows).Count -gt 0) {
            Show-SccmMembership -label "user $($u.Rows[0].UniqueUserName)" -resourceId ([long]$u.Rows[0].ResourceID)
        }
        else { Write-Host "  User $User not resolvable over AdminService." -ForegroundColor Yellow }
    }
}

Write-Host ''
Write-Host 'How to read this:' -ForegroundColor Cyan
Write-Host '  Every SCCM step names the filter shape it tried and whether this site served it -'
Write-Host '  those verdicts, not assumptions, decide how the in-app queries get written.'
Write-Host '  0 collections on a SERVED shape = RBAC hides them from this account; run non-elevated.'
Write-Host '  The Nested timing decides whether the popup can afford an "include nested" option.' -ForegroundColor Yellow
