#Requires -Version 5.1
<#
.SYNOPSIS
    Times the finder's LDAP search against two variants, per forest, then names the rows
    that only one of them returns.

.DESCRIPTION
    Answers the two open questions about DONUT's AD search that cannot be settled by
    reading code, because both change WHICH results come back:

      1. ANR vs the current five-clause OR. Microsoft calls ANR an efficient single-clause
         search across the naming attributes. Its surname half is now carried explicitly by
         the sn clause, so what this comparison still shows is what ANR adds BEYOND that -
         physicalDeliveryOfficeName, proxyAddresses and legacyExchangeDN, which are the
         breadth that crowds real people out of the per-forest cap. Re-run it if the filter
         changes; anything ANR still finds that sn does not is worth a look.
      2. ReferralChasing None vs the default External. AD reaches child domains through
         subordinate references, so turning chasing off is only safe when nothing is being
         referred to - which shows up as an unchanged hit count, not a faster clock.

    Read BOTH columns. A variant that is faster and returns fewer rows is a regression.

    A hit count cannot tell the two ANR outcomes apart: "found Danielson, Kim by surname,
    which no cn=dan* prefix can ever reach" and "matched an office named Danforth" both read
    as +1. So a second, untimed pass re-runs each filter with the ANR attributes loaded and
    prints the symmetric difference, naming every attribute that pulled each extra row in.
    That pass is what settled it: every row ANR added was a surname, so sn went into the
    filter directly and the rest of the ANR set stayed out.

.PARAMETER Prefix
    Search prefixes to time. The default covers both shapes: one token, and a full name
    with a space (the case ANR exists for).

.PARAMETER Domains
    Forests to query. Defaults to the 'domains' key in DONUT's config.json.

.PARAMETER Iterations
    Timed runs per combination; the median is reported. A warm-up runs first and is
    discarded so the LDAP bind is not counted.

.NOTES
    Run as a normal domain user - this only reads the directory, so it needs no elevation
    and elevation would not change the result.

    Filters mirror AdFilter.UserFilter (src/Models/AdSearchResult.psm1) exactly. If that
    changes, change this, or the measurement stops describing the app.

    The identity pass is deliberately separate from the timed one. Attributing a match needs
    givenName/sn/proxyAddresses/physicalDeliveryOfficeName loaded, and widening
    PropertiesToLoad changes what the DC serialises back - folding it into Invoke-Timed would
    corrupt the very measurement this script exists for.

    The diff prints real directory identities (names, sAMAccountNames, offices) to the
    console. It writes nothing to disk; anything shared from it is shared by hand.

    Reference: Creating More Efficient Microsoft Active Directory-Enabled Applications
    https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc755809(v=ws.10)

.EXAMPLE
    pwsh -File tools\Measure-AdSearch.ps1
    Times every configured forest with the default prefixes.

.EXAMPLE
    pwsh -File tools\Measure-AdSearch.ps1 -Domains fabrikam.local -Prefix 'dan' -Iterations 5
    Focuses the slow forest.
#>
[CmdletBinding()]
param(
    [string[]] $Prefix = @('dan', 'danial changez'),
    [string[]] $Domains,
    [int] $Iterations = 3
)

Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

if (-not $Domains) {
    $configPath = Join-Path $env:ProgramData 'DONUT\data\config\config.json'
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "No -Domains given and no config at $configPath." -ForegroundColor Red
        return
    }
    try { $Domains = @((Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json).domains) }
    catch {
        Write-Host "Could not read domains from $configPath : $($_.Exception.Message)" -ForegroundColor Red
        return
    }
}
if (-not $Domains) { Write-Host 'No forests to query.' -ForegroundColor Red; return }

# Mirrors AdFilter.EscapeLdap: the same five characters, so a prefix with a paren or a
# backslash measures the same query the app would send.
function Get-EscapedPrefix([string]$value) {
    $sb = [System.Text.StringBuilder]::new()
    foreach ($ch in $value.ToCharArray()) {
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

function Get-Filter([string]$shape, [string]$escaped) {
    $head = '(&(objectCategory=person)(objectClass=user)'
    if ($shape -eq 'anr') {
        # UPN is not an ANR attribute, so dropping the OR would silently stop UPN searches.
        return "$head(|(anr=$escaped)(userPrincipalName=$escaped*)))"
    }
    return "$head(|(sAMAccountName=$escaped*)(cn=$escaped*)(displayName=$escaped*)" +
    "(userPrincipalName=$escaped*)(sn=$escaped*)))"
}

# Never throws: a forest that is down should report itself, not abort the whole table.
function Invoke-Timed([string]$domain, [string]$filter, [string]$referral) {
    $entry = $null
    $searcher = $null
    try {
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry)
        $searcher.Filter = $filter
        $searcher.SizeLimit = 50          # ActiveDirectoryService MaxPerDomain * 2
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds(10)
        $searcher.ReferralChasing = $referral
        foreach ($p in @('name', 'sAMAccountName', 'userPrincipalName', 'displayName',
                'userAccountControl', 'msDS-User-Account-Control-Computed',
                'distinguishedName', 'objectCategory')) {
            [void]$searcher.PropertiesToLoad.Add($p)
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $found = $searcher.FindAll()
        try { $count = @($found).Count }
        finally { $found.Dispose() }
        $sw.Stop()
        return @{ Ms = [long]$sw.ElapsedMilliseconds; Count = $count }
    } catch { return @{ Error = $_.Exception.Message } }
    finally {
        if ($searcher) { $searcher.Dispose() }
        if ($entry) { $entry.Dispose() }
    }
}

function Get-Median([long[]]$values) {
    $s = @($values | Sort-Object)
    if ($s.Count -eq 0) { return 0 }
    return $s[[int]([math]::Floor($s.Count / 2))]
}

# userPrincipalName is here because the filter ORs it in, not because ANR covers it.
$script:IdentityProps = @('distinguishedName', 'sAMAccountName', 'displayName', 'name',
    'givenName', 'sn', 'userPrincipalName', 'physicalDeliveryOfficeName',
    'proxyAddresses', 'legacyExchangeDN')

# Wider properties so each row can be attributed. Never on the timed path, see .NOTES.
function Get-IdentityRow([string]$domain, [string]$filter) {
    $entry = $null
    $searcher = $null
    try {
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry)
        $searcher.Filter = $filter
        $searcher.SizeLimit = 50          # the same MaxPerDomain * 2 the app caps at
        $searcher.ClientTimeout = [TimeSpan]::FromSeconds(10)
        $searcher.ReferralChasing = 'External'
        foreach ($p in $script:IdentityProps) { [void]$searcher.PropertiesToLoad.Add($p) }

        $rows = [System.Collections.Generic.List[hashtable]]::new()
        $found = $searcher.FindAll()
        try {
            foreach ($res in $found) {
                $h = @{}
                foreach ($p in $script:IdentityProps) {
                    if ($res.Properties.Contains($p)) { $h[$p] = @($res.Properties[$p]) }
                }
                $rows.Add($h)
            }
        } finally { $found.Dispose() }
        return @{ Rows = $rows.ToArray(); Capped = ($rows.Count -ge 50) }
    } catch { return @{ Error = $_.Exception.Message } }
    finally {
        if ($searcher) { $searcher.Dispose() }
        if ($entry) { $entry.Dispose() }
    }
}

# Every attribute whose value starts with the prefix, not just the first: a row matching a
# real name AND an office is a different finding from one matching only the office.
function Get-MatchReason([hashtable]$row, [string]$prefix) {
    $reasons = [System.Collections.Generic.List[string]]::new()
    $cmp = [System.StringComparison]::OrdinalIgnoreCase
    $whole = $prefix.Trim()
    $tokens = @($whole -split '\s+', 2)

    # ANR splits a two-token value across givenName and sn, which the current filter cannot.
    if ($tokens.Count -eq 2) {
        $orders = @(@('givenName', 'sn'), @('sn', 'givenName'))
        foreach ($pair in $orders) {
            $first = [string](@($row[$pair[0]])[0])
            $second = [string](@($row[$pair[1]])[0])
            if ($first.StartsWith($tokens[0], $cmp) -and $second.StartsWith($tokens[1], $cmp)) {
                $reasons.Add("$($pair[0])+$($pair[1])=$first $second")
            }
        }
    }

    foreach ($p in @('givenName', 'sn', 'displayName', 'name', 'sAMAccountName',
            'userPrincipalName', 'physicalDeliveryOfficeName', 'legacyExchangeDN')) {
        foreach ($v in @($row[$p])) {
            $s = [string]$v
            if ($s -and $s.StartsWith($whole, $cmp)) { $reasons.Add("$p=$s"); break }
        }
    }

    # proxyAddresses carry a scheme (SMTP:jane@x), so test the value both with and without it.
    foreach ($v in @($row['proxyAddresses'])) {
        $s = [string]$v
        if (-not $s) { continue }
        $bare = if ($s.Contains(':')) { $s.Substring($s.IndexOf(':') + 1) } else { $s }
        if ($s.StartsWith($whole, $cmp) -or $bare.StartsWith($whole, $cmp)) {
            $reasons.Add("proxyAddresses=$s")
            break
        }
    }

    # Nothing loaded explains it, which is itself a finding: an unread attribute matched.
    if ($reasons.Count -eq 0) { $reasons.Add('unattributed') }
    return $reasons.ToArray()
}

# Prints the rows $left returned that $right did not, each with what pulled it in.
function Write-DiffSection {
    param([string]$Title, [hashtable[]]$Left, [hashtable[]]$Right, [string]$Prefix)

    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($r in $Right) { [void]$seen.Add([string](@($r['distinguishedName'])[0])) }
    $only = @($Left | Where-Object {
            -not $seen.Contains([string](@($_['distinguishedName'])[0]))
        })

    if ($only.Count -eq 0) { Write-Host "  ${Title} (0): none"; return }
    Write-Host "  ${Title} ($($only.Count)):"
    foreach ($r in $only) {
        $sam = [string](@($r['sAMAccountName'])[0])
        $shown = [string](@($r['displayName'])[0])
        if (-not $shown) { $shown = [string](@($r['name'])[0]) }
        $reasons = Get-MatchReason $r $Prefix
        # Only an office or a mail alias matched: exactly the breadth risk ANR carries.
        $noise = @($reasons | Where-Object {
                $_ -notmatch '^(physicalDeliveryOfficeName|proxyAddresses)='
            }).Count -eq 0
        $line = '    {0,-16} {1,-28} {2}' -f $sam, $shown, ($reasons -join '; ')
        if ($noise) { Write-Host "$line    <-- office/proxy only" -ForegroundColor Yellow }
        else { Write-Host $line }
    }
}

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($p in $Prefix) {
    $escaped = Get-EscapedPrefix $p
    foreach ($domain in $Domains) {
        Write-Host "Querying $domain for '$p'..." -ForegroundColor DarkGray
        foreach ($shape in 'current', 'anr') {
            $filter = Get-Filter $shape $escaped
            foreach ($referral in 'External', 'None') {
                # The first bind pays connect and authenticate, which is not under test.
                [void](Invoke-Timed -domain $domain `
                                    -filter $filter `
                                    -referral $referral)

                $times = [System.Collections.Generic.List[long]]::new()
                $count = -1
                $err = ''
                for ($i = 0; $i -lt $Iterations; $i++) {
                    $r = Invoke-Timed -domain $domain `
                                      -filter $filter `
                                      -referral $referral
                    if ($r.Error) { $err = $r.Error; break }
                    $times.Add([long]$r.Ms)
                    $count = [int]$r.Count
                }
                $rows.Add([pscustomobject]@{
                        Prefix   = $p
                        Forest   = $domain
                        Filter   = $shape
                        Referral = $referral
                        Median   = if ($err) { '-' } else { "$(Get-Median $times.ToArray())ms" }
                        Hits     = if ($err) { '-' } else { $count }
                        Note     = $err
                    })
            }
        }
    }
}

Write-Host ''
$rows | Format-Table -AutoSize | Out-String -Width 160 | Write-Host

Write-Host 'Which rows differ (untimed, ReferralChasing=External, same 50-row cap):' -ForegroundColor Cyan
foreach ($p in $Prefix) {
    $escaped = Get-EscapedPrefix $p
    foreach ($domain in $Domains) {
        $cur = Get-IdentityRow $domain (Get-Filter 'current' $escaped)
        $anr = Get-IdentityRow $domain (Get-Filter 'anr' $escaped)
        Write-Host ''
        if ($cur.Error -or $anr.Error) {
            $why = if ($cur.Error) { $cur.Error } else { $anr.Error }
            Write-Host "$domain  '$p'  - could not read: $why" -ForegroundColor Red
            continue
        }
        Write-Host "$domain  '$p'   current $($cur.Rows.Count), anr $($anr.Rows.Count)"
        if ($cur.Capped -or $anr.Capped) {
            Write-Host '  A side reached the 50-row cap, so this diff is truncated.' -ForegroundColor Yellow
        }
        Write-DiffSection -Title 'Only ANR found' `
                          -Left $anr.Rows `
                          -Right $cur.Rows `
                          -Prefix $p
        Write-DiffSection -Title 'Only the current filter found' `
                          -Left $cur.Rows `
                          -Right $anr.Rows `
                          -Prefix $p
    }
}

Write-Host ''
Write-Host 'How to read this:' -ForegroundColor Cyan
Write-Host '  ANR is worth adopting where it is NOT SLOWER and the rows only it finds are people.'
Write-Host '  A name attribute (givenName, sn, givenName+sn) means the current filter cannot reach them.'
Write-Host '  Rows flagged office/proxy only are the breadth risk - they crowd real people out of the cap.'
Write-Host '  Anything under "Only the current filter found" is a person ANR would LOSE.' -ForegroundColor Yellow
Write-Host '  ReferralChasing=None is safe only where Hits is UNCHANGED against External.'
Write-Host '  Fewer hits means referrals are reaching a child domain and must stay on.' -ForegroundColor Yellow
