#Requires -Version 5.1
<#
.SYNOPSIS
    Times the finder's LDAP search against two variants, per forest, with hit counts.

.DESCRIPTION
    Answers the two open questions about DONUT's AD search that cannot be settled by
    reading code, because both change WHICH results come back:

      1. ANR vs the current four-clause OR. Microsoft calls ANR an efficient single-clause
         search across the naming attributes, and it is the only shape that handles
         "first last" (it matches givenName AND sn), which the current filter cannot. But
         ANR is schema-level: it also matches physicalDeliveryOfficeName and proxyAddresses,
         so it can return people the current filter would not.
      2. ReferralChasing None vs the default External. AD reaches child domains through
         subordinate references, so turning chasing off is only safe when nothing is being
         referred to - which shows up as an unchanged hit count, not a faster clock.

    Read BOTH columns. A variant that is faster and returns fewer rows is a regression.

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

    Reference: Creating More Efficient Microsoft Active Directory-Enabled Applications
    https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc755809(v=ws.10)

.EXAMPLE
    pwsh -File tools\Measure-AdSearch.ps1
    Times every configured forest with the default prefixes.

.EXAMPLE
    pwsh -File tools\Measure-AdSearch.ps1 -Domains forest-d.local -Prefix 'dan' -Iterations 5
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
        # userPrincipalName stays ORed in: UPN is NOT one of the ANR attributes, so
        # dropping it here would silently stop UPN searches working in the app.
        return "$head(|(anr=$escaped)(userPrincipalName=$escaped*)))"
    }
    return "$head(|(sAMAccountName=$escaped*)(cn=$escaped*)(displayName=$escaped*)(userPrincipalName=$escaped*)))"
}

# One run: returns @{ Ms; Count } or @{ Error }. Never throws - a forest that is down
# should report itself, not abort the whole table.
function Invoke-Timed([string]$domain, [string]$filter, [string]$referral) {
    $entry = $null
    $searcher = $null
    try {
        $entry = [System.DirectoryServices.DirectoryEntry]::new("LDAP://$domain")
        $searcher = [System.DirectoryServices.DirectorySearcher]::new($entry)
        $searcher.Filter = $filter
        $searcher.SizeLimit = 16          # AdSearchResult's MaxPerDomain * 2
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
    }
    catch { return @{ Error = $_.Exception.Message } }
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

$rows = [System.Collections.Generic.List[object]]::new()
foreach ($p in $Prefix) {
    $escaped = Get-EscapedPrefix $p
    foreach ($domain in $Domains) {
        Write-Host "Querying $domain for '$p'..." -ForegroundColor DarkGray
        foreach ($shape in 'current', 'anr') {
            $filter = Get-Filter $shape $escaped
            foreach ($referral in 'External', 'None') {
                # Warm-up: the first bind to a forest pays connect + authenticate, which is
                # not what any of these variants is being judged on.
                [void](Invoke-Timed -domain $domain -filter $filter -referral $referral)

                $times = [System.Collections.Generic.List[long]]::new()
                $count = -1
                $err = ''
                for ($i = 0; $i -lt $Iterations; $i++) {
                    $r = Invoke-Timed -domain $domain -filter $filter -referral $referral
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

Write-Host 'How to read this:' -ForegroundColor Cyan
Write-Host '  ANR is worth adopting only where it is FASTER and returns AT LEAST as many hits.'
Write-Host '  Its own reason to exist is the multi-word prefix - compare those rows first.'
Write-Host '  ReferralChasing=None is safe only where Hits is UNCHANGED against External.'
Write-Host '  Fewer hits means referrals are reaching a child domain and must stay on.' -ForegroundColor Yellow
