#Requires -Version 5.1
<#
.SYNOPSIS
    Probes the two field facts the cross-forest device identity fixes rest on.

.DESCRIPTION
    Run as the operator (non-elevated is fine) on a box that reaches the DC and,
    for section 2, the AdminService as an account with SCCM RBAC access. Every
    step is a read: DNS queries, AdminService GETs, LDAP binds.

      1. DNS: how the bare name resolves against the active DC versus the FQDN
         built from its home domain, next to this box's suffix search list. The
         resolve workers now try "<host>.<domain>" first when the pick knew the
         domain, and fall back to the bare name.
      2. SCCM: whether SMS_R_System exposes DistinguishedName and FullDomainName
         for the machine's ResourceID over this site's route, what the keyed
         segment answers, and whether that DN binds. The Lens device read now
         asks this on a GC miss, ahead of the per-domain sweep.

    Pick a machine that lives OUTSIDE the forest you are logged on to for the
    strongest signal; a home-forest machine only proves nothing regressed.

.PARAMETER HostName
    The machine's short name, as the finder or Lens shows it.

.PARAMETER Domain
    Its home AD DNS domain (what the finder row's Domain column carries), e.g.
    sibling.corp.local. Optional: without it section 1 shows the bare name only.

.PARAMETER Dc
    DNS server to ask, normally the active DC. Defaults to this session's logon
    server.

.PARAMETER SiteServer
    AdminService host. Optional: without it section 2 is skipped.

.EXAMPLE
    pwsh -File tools\Probe-DeviceIdentity.ps1 -HostName PC-123 -Domain sibling.corp.local -SiteServer sccm.corp.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $HostName,
    [string] $Domain = '',
    [string] $Dc = ($env:LOGONSERVER -replace '^\\\\', ''),
    [string] $SiteServer = ''
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Invoke-AdminServiceGet([string]$query) {
    $p = @{
        Uri = "https://$SiteServer/AdminService/wmi/$query"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    $r = Invoke-RestMethod @p
    if ($null -ne $r.PSObject.Properties['value']) { return @($r.value) }
    return @($r)
}

# One timed DNS query, printed as the app would see it: first A record or nothing.
function Show-Resolve([string]$label, [string]$name, [string]$server) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $p = @{ Name = $name; Type = 'A'; ErrorAction = 'Stop' }
        if ($server) { $p.Server = $server }
        $ips = @(Resolve-DnsName @p | Where-Object { $_.IPAddress } | ForEach-Object { $_.IPAddress })
        if ($ips.Count -gt 0) {
            Write-Host ("  {0,-34} {1}  ({2} ms)" -f $label, ($ips -join ', '), $sw.ElapsedMilliseconds) -ForegroundColor Green
            return $ips[0]
        }
        Write-Host ("  {0,-34} no A record  ({1} ms)" -f $label, $sw.ElapsedMilliseconds) -ForegroundColor Yellow
    }
    catch {
        Write-Host ("  {0,-34} ERR {1}  ({2} ms)" -f $label, $_.Exception.Message, $sw.ElapsedMilliseconds) -ForegroundColor Red
    }
    return ''
}

Write-Host 'DONUT device identity probe (read-only)' -ForegroundColor White
Write-Host "  host '$HostName'  domain '$Domain'  dc '$Dc'  site '$SiteServer'"

Write-Host "`n=== 1. DNS: bare name vs FQDN ===" -ForegroundColor Cyan
try {
    $g = Get-DnsClientGlobalSetting
    Write-Host "  suffix search list : $(@($g.SuffixSearchList) -join ', ')"
}
catch { Write-Host "  suffix search list : (unavailable: $($_.Exception.Message))" }
try {
    Write-Host "  this box's domain  : $((Get-CimInstance Win32_ComputerSystem).Domain)"
}
catch { }
Write-Host ''
$null = Show-Resolve -label 'bare, local resolver' -name $HostName -server ''
$bareDc = Show-Resolve -label 'bare, via DC' -name $HostName -server $Dc
$fqdnDc = ''
if ($Domain) { $fqdnDc = Show-Resolve -label "FQDN '$HostName.$Domain', via DC" -name "$HostName.$Domain" -server $Dc }
Write-Host ''
if ($Domain -and $fqdnDc -and $bareDc -and $fqdnDc -ne $bareDc) {
    Write-Host "  BARE AND FQDN DISAGREE: the bare name reaches a DIFFERENT machine ($bareDc vs $fqdnDc)." -ForegroundColor Red
}
elseif ($Domain -and $fqdnDc -and -not $bareDc) {
    Write-Host '  bare name fails, FQDN resolves: exactly the false-Offline the fix removes.' -ForegroundColor Yellow
}
elseif ($Domain -and $fqdnDc) {
    Write-Host '  both agree: a home-forest machine, or the suffix list already covers this domain.' -ForegroundColor Green
}
elseif ($Domain -and -not $fqdnDc) {
    Write-Host "  FQDN did not resolve: the machine's DNS zone is not '$Domain' (disjoint namespace?), the bare fallback carries it." -ForegroundColor Yellow
}

if ($SiteServer) {
    Write-Host "`n=== 2. SCCM: SMS_R_System discovery record ===" -ForegroundColor Cyan
    $resourceId = ''
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $rows = Invoke-AdminServiceGet ("SMS_R_System?`$filter=" +
            [uri]::EscapeDataString("Name eq '$HostName'") +
            "&`$select=ResourceID,Name,DistinguishedName,FullDomainName,ResourceDomainORWorkgroup,Obsolete")
        Write-Host "  OK  $($rows.Count) record(s) by name  ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
        $rows | Format-Table ResourceID, Name, FullDomainName, ResourceDomainORWorkgroup, Obsolete, DistinguishedName -AutoSize |
            Out-String -Width 200 | Write-Host
        $live = @($rows | Where-Object { -not $_.Obsolete })
        $pick = if ($live.Count -gt 0) { $live[0] } else { $rows | Select-Object -First 1 }
        if ($pick) { $resourceId = [string]$pick.ResourceID }
        if ($rows.Count -gt 1) { Write-Host '  more than one record: SCCM holds duplicates or obsoletes for this name.' -ForegroundColor Yellow }
    }
    catch { Write-Host "  ERR  by-name filter: $($_.Exception.Message)" -ForegroundColor Red }

    if ($resourceId) {
        Write-Host "`n  -- keyed segment SMS_R_System($resourceId), the exact read the Lens device job makes --" -ForegroundColor White
        $sccmDn = ''
        $fullDomain = ''
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $row = Invoke-AdminServiceGet "SMS_R_System($resourceId)?`$select=DistinguishedName,FullDomainName" |
                Select-Object -First 1
            Write-Host "  OK  ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
            $sccmDn = [string]$row.DistinguishedName
            $fullDomain = [string]$row.FullDomainName
            Write-Host "  DistinguishedName : '$sccmDn'"
            Write-Host "  FullDomainName    : '$fullDomain'"
            if (-not $sccmDn) {
                Write-Host '  DistinguishedName is EMPTY: AD System Discovery does not populate it here, or the property is named differently.' -ForegroundColor Yellow
                $full = Invoke-AdminServiceGet "SMS_R_System($resourceId)" | Select-Object -First 1
                $names = @($full.PSObject.Properties | Where-Object { $_.Name -match 'Distinguished|Domain|OU' } |
                        ForEach-Object { "$($_.Name)='$($_.Value)'" })
                Write-Host "  related properties on the full row: $($names -join '; ')"
            }
        }
        catch { Write-Host "  ERR  keyed segment: $($_.Exception.Message)" -ForegroundColor Red }

        if ($sccmDn) {
            Write-Host "`n  -- LDAP bind of that DN (serverless, the locator picks the domain) --" -ForegroundColor White
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $entry = [ADSI]"LDAP://$sccmDn"
                $entry.psbase.RefreshCache()
                Write-Host "  OK  bound as '$($entry.Properties['name'][0])', dNSHostName '$($entry.Properties['dnshostname'][0])'  ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
                $dnDomain = (($sccmDn -split ',' | Where-Object { $_ -match '^DC=' } | ForEach-Object { $_.Substring(3) }) -join '.')
                Write-Host "  DN's domain '$dnDomain'  vs FullDomainName '$fullDomain'  vs -Domain '$Domain'"
            }
            catch { Write-Host "  ERR  bind failed (stale DN after an OU move, or no trust path): $($_.Exception.Message)" -ForegroundColor Red }
        }
    }

    Write-Host "`n  -- the GC search the device job tries FIRST (this forest only) --" -ForegroundColor White
    try {
        $forestNc = [string]([ADSI]'LDAP://RootDSE').Properties['rootDomainNamingContext'][0]
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $gc = New-Object System.DirectoryServices.DirectorySearcher
        $gc.SearchRoot = [ADSI]"GC://$forestNc"
        $gc.Filter = "(&(objectCategory=computer)(cn=$HostName))"
        $gc.ClientTimeout = [TimeSpan]::FromSeconds(15)
        [void]$gc.PropertiesToLoad.Add('distinguishedName')
        $hit = $gc.FindOne()
        if ($hit) {
            Write-Host "  HIT  $($hit.Properties['distinguishedname'][0])  ($($sw.ElapsedMilliseconds) ms): the SCCM read never runs for this machine." -ForegroundColor Green
        }
        else {
            Write-Host "  MISS ($($sw.ElapsedMilliseconds) ms): the SCCM read above is what saves this machine from the domain sweep." -ForegroundColor Yellow
        }
    }
    catch { Write-Host "  ERR  GC search: $($_.Exception.Message)" -ForegroundColor Red }
}

Write-Host "`nInterpretation:" -ForegroundColor White
Write-Host '  1: bare and FQDN agree                          -> no behaviour change for this machine.'
Write-Host '  1: bare fails or disagrees, FQDN resolves       -> the domain hint fixes a real false-Offline or wrong-machine case.'
Write-Host '  2: DistinguishedName populated and the DN binds -> the GC-miss path pins the exact machine in one read.'
Write-Host '  2: DistinguishedName empty                      -> report the related property names; FullDomainName alone still leads the sweep.'
Write-Host '  2: keyed segment ERR                            -> report the message; the filter form is the fallback to wire.'
Write-Host '  2: keyed segment fast (well under a second)     -> say so, and the SCCM read can move ahead of the GC search.'
