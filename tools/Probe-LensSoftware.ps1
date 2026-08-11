#Requires -Version 5.1
<#
.SYNOPSIS
    Probes the AdminService shapes the Lens software list depends on, before wiring.

.DESCRIPTION
    Run in a non-elevated pwsh as an account with SCCM RBAC access (the same identity
    the Lens agent runs as), on a box that reaches the AdminService. Every request is
    a read-only GET. It walks the exact chain the feature will use:

      1. SMS_R_User by endswith(UniqueUserName) -> the user's ResourceID(s)
      2. SMS_FullCollectionMembership by ResourceID eq N -> the user's CollectionIDs
      3. SMS_DeploymentSummary ($select only) -> filtered client-side to the rows the
         app would show (FeatureType 1 = Application, DesiredConfigType 1 = Install,
         CollectionID in the membership set)

    Compare the final rows against the ConfigMgr console: user Properties ->
    Deployments. A match confirms the design; the Interpretation footer maps every
    mismatch to the code change it forces.

.PARAMETER SiteServer
    AdminService host (the same value DONUT's config carries).

.PARAMETER Sam
    The user's SAM account name (no domain prefix), e.g. jdoe.

.EXAMPLE
    pwsh -File tools\Probe-LensSoftware.ps1 -SiteServer sccm.corp.com -Sam jdoe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $Sam
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Get-AdminServiceRows([string]$query) {
    $p = @{
        Uri = "https://$SiteServer/AdminService/wmi/$query"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 15
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return @((Invoke-RestMethod @p).value)
}

Write-Host 'DONUT Lens software probe (read-only)' -ForegroundColor White

Write-Host "`n=== 1. SMS_R_User: endswith(UniqueUserName,'$Sam') ===" -ForegroundColor Cyan
$ids = @()
try {
    $users = Get-AdminServiceRows ("SMS_R_User?`$filter=" +
        [uri]::EscapeDataString("endswith(UniqueUserName,'$Sam')") +
        "&`$select=ResourceID,UniqueUserName")
    Write-Host "  OK  $($users.Count) row(s)" -ForegroundColor Green
    $users | Select-Object -First 5 | Format-Table UniqueUserName, ResourceID -AutoSize | Out-String | Write-Host
    # The exact tail match is what the app applies, so the probe applies it too.
    $ids = @($users | Where-Object { ($_.UniqueUserName -split '\\')[-1] -eq $Sam } |
            ForEach-Object { [string]$_.ResourceID })
    Write-Host "  exact-tail ResourceID(s): $($ids -join ', ')" -ForegroundColor White
    if ($ids.Count -eq 0) { Write-Host '  NO EXACT MATCH - check the SAM spelling' -ForegroundColor Red }
}
catch { Write-Host "  ERR  $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`n=== 2. SMS_FullCollectionMembership: ResourceID eq N ===" -ForegroundColor Cyan
$collections = [System.Collections.Generic.HashSet[string]]::new()
foreach ($id in $ids) {
    try {
        $rows = Get-AdminServiceRows ("SMS_FullCollectionMembership?`$filter=" +
            [uri]::EscapeDataString("ResourceID eq $id") + "&`$select=CollectionID")
        Write-Host "  OK  ResourceID $id is in $($rows.Count) collection(s)" -ForegroundColor Green
        foreach ($r in $rows) { [void]$collections.Add([string]$r.CollectionID) }
    }
    catch { Write-Host "  ERR  ResourceID ${id}: $($_.Exception.Message)" -ForegroundColor Red }
}
if ($collections.Count -gt 0) {
    Write-Host "  first few: $((@($collections) | Select-Object -First 8) -join ', ')"
}

Write-Host "`n=== 3. SMS_DeploymentSummary: one `$select fetch, filtered client-side ===" -ForegroundColor Cyan
try {
    $sum = Get-AdminServiceRows ("SMS_DeploymentSummary?`$select=" +
        'SoftwareName,CollectionName,CollectionID,FeatureType,DesiredConfigType')
    Write-Host "  OK  $($sum.Count) deployment row(s) site-wide" -ForegroundColor Green
    $withFeature = @($sum | Where-Object { $null -ne $_.PSObject.Properties['FeatureType'] })
    $withConfig = @($sum | Where-Object { $null -ne $_.PSObject.Properties['DesiredConfigType'] })
    Write-Host "  rows carrying FeatureType: $($withFeature.Count)   DesiredConfigType: $($withConfig.Count)"
    $mine = @($sum | Where-Object {
            [int]$_.FeatureType -eq 1 -and [int]$_.DesiredConfigType -eq 1 -and
            $collections.Contains([string]$_.CollectionID) })
    Write-Host "`n  == the $($mine.Count) row(s) the app would show for '$Sam' ==" -ForegroundColor White
    $mine | Sort-Object SoftwareName | Format-Table SoftwareName, CollectionName -AutoSize | Out-String | Write-Host
}
catch { Write-Host "  ERR  $($_.Exception.Message)" -ForegroundColor Red }

Write-Host "`nInterpretation:" -ForegroundColor White
Write-Host '  all three hops OK + final rows match the console Deployments tab -> design confirmed as is.'
Write-Host '  hop 1 or 2 ERR (404)                    -> that filter shape is not served, report the message.'
Write-Host '  hop 2 OK with 0 rows for a user who has collections -> 200-empty rejection, report it.'
Write-Host '  DesiredConfigType count is 0            -> the route drops it, the Install filter becomes -ne 2.'
Write-Host '  site-wide row count in the many thousands -> report it, the fetch gains a server-side FeatureType filter.'
