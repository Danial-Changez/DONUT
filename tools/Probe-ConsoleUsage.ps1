#Requires -Version 5.1
<#
.SYNOPSIS
    Probes whether this site can answer "when was this PERSON last on this machine".

.DESCRIPTION
    The Lens device row prints "seen <ago>" from the COMPUTER object's AD
    lastLogonTimestamp, which is the machine authenticating to the domain, not a
    user session. That is why a pool of WVD hosts shows a spread of dates nobody
    logged into. This probe asks whether a per-user answer exists here instead.

    Run as the operator (non-elevated is fine) on a box that reaches the DC and
    the AdminService with SCCM RBAC access. Every step is a read: AdminService
    GETs and LDAP binds, no writes.

    Per machine the person owns, it prints side by side:

      1. AD lastLogonTimestamp on the computer object - today's "seen" value, so
         the comparison below is against what actually ships.
      2. SMS_G_System_SYSTEM_CONSOLE_USER - SystemConsoleUser / LastConsoleUse /
         NumberOfConsoleLogons. The only true per-user-per-machine source, and the
         only one that could replace the label. Needs the Console Usage hardware
         inventory class enabled on the site.
      3. SMS_G_System_SYSTEM_CONSOLE_USAGE - TopConsoleUser, the heaviest user of
         the box. A weaker fallback: it names one winner, not this person.
      4. SMS_R_System - LastLogonUserName / LastLogonTimestamp. Machine scoped,
         but it says WHO logged on last, so it can at least qualify the label.

    Each class is tried with the "ResourceID eq N" filter first and the keyed
    segment Class(N) second, because a rejected AdminService filter answers 404
    OR 200-empty (see docs/development/decisions.md#adminservice-filter-shapes).

.PARAMETER Sam
    The person's SAM account name, as the Lens shows it. Affinity resolves it to
    machines the same way the Lens does: endswith on the forest-unique SAM.

.PARAMETER SiteServer
    AdminService host, e.g. sccm.corp.com.

.PARAMETER ResourceId
    Probe one machine directly by its SCCM ResourceID, skipping the affinity
    lookup. Use when affinity is not the part in question.

.PARAMETER MaxDevices
    How many of the person's machines to probe. Defaults to 5, since each device
    costs four round trips against a site that answers slowly per query.

.EXAMPLE
    pwsh -File tools\Probe-ConsoleUsage.ps1 -Sam CE452807 -SiteServer sccm.corp.com

.EXAMPLE
    pwsh -File tools\Probe-ConsoleUsage.ps1 -ResourceId 16777345 -SiteServer sccm.corp.com
#>
[CmdletBinding()]
param(
    [string] $Sam = '',
    [Parameter(Mandatory)] [string] $SiteServer,
    [int] $ResourceId = 0,
    [int] $MaxDevices = 5
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Invoke-AdminServiceGet([string]$query) {
    $p = @{
        Uri = "https://$SiteServer/AdminService/wmi/$query"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 20
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    $r = Invoke-RestMethod @p
    if ($null -ne $r.PSObject.Properties['value']) { return @($r.value) }
    return @($r)
}

# Filter first, keyed segment second: a rejected filter answers 404 OR 200-empty.
function Get-ClassResult([string]$class, [string]$select, [int]$id) {
    $out = [ordered]@{ Rows = @(); Route = ''; Error = '' }
    $filter = [uri]::EscapeDataString("ResourceID eq $id")
    try {
        $rows = @(Invoke-AdminServiceGet "${class}?`$filter=$filter&`$select=$select")
        if ($rows.Count -gt 0) {
            $out.Rows = $rows; $out.Route = 'filter'
            return $out
        }
        $out.Error = '200-empty on filter'
    } catch { $out.Error = "filter: $($_.Exception.Message)" }
    try {
        $rows = @(Invoke-AdminServiceGet "$class($id)?`$select=$select")
        if ($rows.Count -gt 0) {
            $out.Rows = $rows; $out.Route = 'keyed'; $out.Error = ''
        }
    } catch { $out.Error += "; keyed: $($_.Exception.Message)" }
    return $out
}

# The AD value the Lens prints today, so every per-user candidate has a baseline.
function Get-AdLastLogon([string]$name) {
    try {
        $root = [ADSI]'LDAP://RootDSE'
        $nc = [string]$root.Properties['defaultNamingContext'][0]
        $ds = New-Object System.DirectoryServices.DirectorySearcher([ADSI]"LDAP://$nc")
        $ds.Filter = "(&(objectCategory=computer)(cn=$name))"
        $ds.ClientTimeout = [TimeSpan]::FromSeconds(10)
        [void]$ds.PropertiesToLoad.Add('lastlogontimestamp')
        $hit = $ds.FindOne()
        if (-not $hit) { return 'no computer object found' }
        if ($hit.Properties['lastlogontimestamp'].Count -eq 0) { return 'no lastLogonTimestamp' }
        $ft = [int64]$hit.Properties['lastlogontimestamp'][0]
        if ($ft -le 0) { return 'lastLogonTimestamp 0' }
        return [datetime]::FromFileTimeUtc($ft).ToString('yyyy-MM-dd HH:mm') + ' UTC'
    } catch { return "ERR $($_.Exception.Message)" }
}

function Show-Section([string]$label, [object]$probe, [string[]]$fields) {
    if ($probe.Rows.Count -eq 0) {
        Write-Host ("    {0,-34} none  ({1})" -f $label, $probe.Error) -ForegroundColor Yellow
        return
    }
    Write-Host ("    {0,-34} {1} row(s) via {2}" -f $label, $probe.Rows.Count, $probe.Route) `
               -ForegroundColor Green
    foreach ($row in $probe.Rows) {
        $parts = foreach ($f in $fields) {
            $v = $row.PSObject.Properties[$f]
            "{0}={1}" -f $f, $(if ($v) { $v.Value } else { '<absent>' })
        }
        Write-Host ("      " + ($parts -join '  '))
    }
}

Write-Host 'DONUT console usage probe (read-only)' -ForegroundColor White
Write-Host "  sam '$Sam'  site '$SiteServer'  resourceId '$ResourceId'"

# --- 1. the person's machines, resolved exactly as the Lens resolves them ---
$devices = @()
if ($ResourceId -gt 0) {
    $devices = @([pscustomobject]@{ Name = "ResourceID $ResourceId"; ResourceId = $ResourceId })
} elseif ($Sam) {
    Write-Host "`n=== 1. affinity: person -> machines ===" -ForegroundColor Cyan
    try {
        $filter = [uri]::EscapeDataString("endswith(UniqueUserName,'$Sam')")
        $rows = @(Invoke-AdminServiceGet ("SMS_UserMachineRelationship?`$filter=$filter" +
                "&`$select=UniqueUserName,ResourceName,ResourceID"))
        # endswith can catch a same-tail SAM in another domain, so match the tail exactly.
        $mine = @($rows | Where-Object { ([string]$_.UniqueUserName -split '\\')[-1] -eq $Sam })
        Write-Host "  $($rows.Count) affinity row(s), $($mine.Count) exact-tail match(es)"
        $devices = @($mine | Select-Object -First $MaxDevices | ForEach-Object {
                [pscustomobject]@{ Name = [string]$_.ResourceName; ResourceId = [int]$_.ResourceID }
            })
    } catch {
        Write-Host "  affinity FAILED: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host '  supply -Sam or -ResourceId.' -ForegroundColor Red
}

if ($devices.Count -eq 0) {
    Write-Host "`nNothing to probe." -ForegroundColor Yellow
    return
}

# --- 2. per machine: today's AD value, then every per-user candidate ---
$anyPerUser = $false
foreach ($d in $devices) {
    Write-Host "`n=== $($d.Name)  (ResourceID $($d.ResourceId)) ===" -ForegroundColor Cyan
    if ($d.Name -notlike 'ResourceID *') {
        Write-Host ("    {0,-34} {1}" -f 'AD lastLogonTimestamp (today)', (Get-AdLastLogon $d.Name))
    }

    $consoleUser = Get-ClassResult -class 'SMS_G_System_SYSTEM_CONSOLE_USER' `
                                   -select 'SystemConsoleUser,LastConsoleUse,NumberOfConsoleLogons' `
                                   -id $d.ResourceId
    Show-Section -label 'CONSOLE_USER (per user)' `
                 -probe $consoleUser `
                 -fields @('SystemConsoleUser', 'LastConsoleUse', 'NumberOfConsoleLogons')
    if ($consoleUser.Rows.Count -gt 0) { $anyPerUser = $true }

    $usage = Get-ClassResult -class 'SMS_G_System_SYSTEM_CONSOLE_USAGE' `
                             -select 'TopConsoleUser,TotalConsoleTime' `
                             -id $d.ResourceId
    Show-Section -label 'CONSOLE_USAGE (top user)' `
                 -probe $usage `
                 -fields @('TopConsoleUser', 'TotalConsoleTime')

    $sys = Get-ClassResult -class 'SMS_R_System' `
                           -select 'Name,LastLogonUserName,LastLogonTimestamp' `
                           -id $d.ResourceId
    Show-Section -label 'R_System (last user on box)' `
                 -probe $sys `
                 -fields @('LastLogonUserName', 'LastLogonTimestamp')
}

# --- 3. the verdict the label change hangs on ---
Write-Host "`n=== verdict ===" -ForegroundColor Cyan
if ($anyPerUser) {
    $verdict = '  SYSTEM_CONSOLE_USER answers here, so "seen" can become a real per-user ' +
    'logon: match SystemConsoleUser to the picked person and read LastConsoleUse.'
    Write-Host $verdict -ForegroundColor Green
    Write-Host ('  Check above that this person appears on their own machines, and that ' +
        'LastConsoleUse is fresher than the AD value it would replace.')
} else {
    Write-Host ('  SYSTEM_CONSOLE_USER returned nothing on every device, so the Console Usage ' +
        'inventory class is not collected on this site.') -ForegroundColor Yellow
    Write-Host ('  Then "seen" cannot be made per-user from SCCM as it stands: either enable ' +
        'that class in Client Settings, or relabel the row so it stops implying a user session.')
}
