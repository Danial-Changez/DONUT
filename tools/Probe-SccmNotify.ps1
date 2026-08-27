#Requires -Version 5.1
<#
.SYNOPSIS
    Probes whether this account can push approved software to a person's device
    through its SCCM collection, over the AdminService, before the feature is wired.

.DESCRIPTION
    Run in a non-elevated pwsh as the account whose SCCM rights DONUT's Lens lane
    already uses, on a box that reaches the AdminService. Sections 1 to 4 are GETs
    and change nothing. The three switches each perform one write and run only when
    passed: -Push adds the target to the software's collection, -Notify tells the
    device to fetch policy now, -Retract removes the target again.

      1. SMS_Admin: every administrative user and group, and which of them is you,
         since rights usually arrive through a group.
      2. SMS_DeploymentSummary: the software catalog, each app over the collection
         that carries it, with the collection's type (user or device) and the
         deployment's intent (Required installs, Available waits in Software Center).
      3. The target's ResourceID, whether it is already in that collection, the
         collection's own rules (a query on an AD group means the site feeds it
         from AD, and the push may belong in the group instead), and its security
         scopes, which a role must be granted on for a push to be allowed.
      4. SMS_ClientOperation: the class -Notify writes to, read as it stands.
      5. -Push: SMS_Collection(id).AddMembershipRule with a direct rule, then
         RequestRefresh and a poll until the membership shows. With -Wmi the same
         two calls go to the SMS Provider over DCOM, the console's own route.
      6. -Notify: SMS_ClientOperation.InitiateClientOperationEx, Download Computer
         Policy, to the device alone.
      7. -Retract: DeleteMembershipRule, then RequestRefresh, over either route.

    Pick a throwaway device or account and a harmless app. A Required deployment
    installs on the next policy fetch, so -Push without -Notify, then -Retract, is
    the quiet round trip. Cross-check in the console: the collection's members, and
    Monitoring, Client Operations for the notification.

.PARAMETER SiteServer
    AdminService host (the same value DONUT's config carries).

.PARAMETER Software
    The app's name, exactly as section 2's list prints it. Run without it first
    and copy one.

.PARAMETER Collection
    A collection ID or name, only when the app is deployed to more than one.

.PARAMETER Target
    A machine's short name, for a device collection and for -Notify.

.PARAMETER Sam
    A user's SAM account name, for a user collection.

.PARAMETER Push
    Adds the target to the software's collection. Refused against the box or
    account running the probe.

.PARAMETER Notify
    Sends Download Computer Policy to -Target.

.PARAMETER Retract
    Removes the target from the software's collection.

.PARAMETER Wmi
    Runs -Push and -Retract against the SMS Provider over DCOM instead of the
    AdminService: the A/B when the REST call fails, since the provider's error is
    the real one and a rule that lands here proves the rights and the rule shape.

.EXAMPLE
    pwsh -File tools\Probe-SccmNotify.ps1 -SiteServer sccm.corp.com

.EXAMPLE
    pwsh -File tools\Probe-SccmNotify.ps1 -SiteServer sccm.corp.com -Software Greenshot -Target PC-123 -Push -Notify

.EXAMPLE
    pwsh -File tools\Probe-SccmNotify.ps1 -SiteServer sccm.corp.com -Software Greenshot -Target PC-123 -Retract
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SiteServer,
    [string] $Software = '',
    [string] $Collection = '',
    [string] $Target = '',
    [string] $Sam = '',
    [switch] $Push,
    [switch] $Notify,
    [switch] $Retract,
    [switch] $Wmi
)

if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

function Invoke-AdminService([string]$query, [hashtable]$body) {
    $p = @{
        Uri = "https://$SiteServer/AdminService/wmi/$query"
        UseDefaultCredentials = $true; ErrorAction = 'Stop'; TimeoutSec = 30
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    if ($null -ne $body) {
        $p.Method = 'Post'
        $p.ContentType = 'application/json'
        $p.Body = ($body | ConvertTo-Json -Compress -Depth 4)
    }
    $r = Invoke-RestMethod @p
    if ($null -ne $r.PSObject.Properties['value']) { return @($r.value) }
    return @($r)
}

function Write-Section([string]$title) { Write-Host "`n=== $title ===" -ForegroundColor Cyan }
function Write-Err([string]$text) { Write-Host "  ERR  $text" -ForegroundColor Red }

# The provider's own message rides the response body, which is where a 500 explains itself.
function Write-Fail($err) {
    Write-Err $err.Exception.Message
    if ($err.ErrorDetails -and $err.ErrorDetails.Message) {
        Write-Host "       $($err.ErrorDetails.Message)" -ForegroundColor Red
    }
}

# Members of one collection: the filter first, the per-collection class when it is not served.
function Get-CollectionMember([string]$collectionId) {
    try {
        $rows = Invoke-AdminService ("SMS_FullCollectionMembership?`$filter=" +
            [uri]::EscapeDataString("CollectionID eq '$collectionId'") + '&$select=ResourceID,Name')
        if ($rows.Count -gt 0) { return $rows }
    } catch { }
    return Invoke-AdminService "SMS_CM_RES_COLL_$collectionId?`$select=ResourceID,Name"
}

# The console's own route: the SMS Provider over DCOM, with the collection and the rule as
# CIM instances, since that is the shape its methods take.
function Connect-Provider([string]$collectionId, [string]$class, [int]$id, [string]$name) {
    $opt = New-CimSessionOption -Protocol Dcom
    $s = New-CimSession -ComputerName $SiteServer `
                        -SessionOption $opt `
                        -ErrorAction Stop
    $loc = Get-CimInstance -CimSession $s `
                           -Namespace 'root\SMS' `
                           -ClassName SMS_ProviderLocation `
                           -ErrorAction Stop |
        Where-Object { $_.ProviderForLocalSite } | Select-Object -First 1
    if (-not $loc) { throw "root\SMS on $SiteServer names no provider for the local site" }
    if ($loc.Machine -and $loc.Machine -notlike "$SiteServer*") {
        $s = New-CimSession -ComputerName $loc.Machine `
                            -SessionOption $opt `
                            -ErrorAction Stop
    }
    $ns = "root\SMS\site_$($loc.SiteCode)"
    Write-Host "  provider : $($loc.Machine)  $ns" -ForegroundColor White
    $coll = Get-CimInstance -CimSession $s `
                            -Namespace $ns `
                            -ClassName SMS_Collection `
                            -Filter "CollectionID='$collectionId'"
    if (-not $coll) { throw "$collectionId is not visible through the provider" }
    $cls = Get-CimClass -CimSession $s `
                        -Namespace $ns `
                        -ClassName SMS_CollectionRuleDirect
    $props = @{ ResourceClassName = $class; ResourceID = [uint32]$id; RuleName = $name }
    $rule = New-CimInstance -CimClass $cls `
                            -ClientOnly `
                            -Property $props
    return @{ Session = $s; Collection = $coll; Rule = $rule }
}

Write-Host 'DONUT SCCM push probe (reads only, unless -Push, -Notify or -Retract)' -ForegroundColor White
Write-Host "  site '$SiteServer'  software '$Software'  target '$Target'  sam '$Sam'"

Write-Section '1. SMS_Admin: the identity your rights come from'
$me = "$env:USERDOMAIN\$env:USERNAME"
# Rights usually arrive through a group, so every group in the token counts as you.
$groups = @([System.Security.Principal.WindowsIdentity]::GetCurrent().Groups | ForEach-Object {
        try { $_.Translate([System.Security.Principal.NTAccount]).Value } catch { }
    })
try {
    # No filter: a backslash in a URL 404s on this route, so the match is client side.
    $admins = Invoke-AdminService ('SMS_Admin?$select=AdminID,LogonName,IsGroup,RoleNames,' +
        'CategoryNames,CollectionNames')
    Write-Host "  OK  $($admins.Count) administrative user(s) and group(s); you are in $($groups.Count) groups" `
               -ForegroundColor Green
    $admins | Sort-Object LogonName | Format-Table LogonName, IsGroup, RoleNames, CategoryNames -AutoSize |
        Out-String -Width 200 | Write-Host
    $mine = @($admins | Where-Object { [string]$_.LogonName -ieq $me -or $groups -contains [string]$_.LogonName })
    if ($mine.Count -eq 0) {
        Write-Host ("  no row is $me or a group in your token, yet the reads work: " +
            'a nested group, so the console, Administrative Users, names it') -ForegroundColor Yellow
    }
    foreach ($a in $mine) {
        Write-Host "  you, as $($a.LogonName) (AdminID $($a.AdminID))" -ForegroundColor White
        Write-Host "    roles       : $(@($a.RoleNames) -join ', ')"
        Write-Host "    scopes      : $(@($a.CategoryNames) -join ', ')"
        Write-Host "    collections : $(@($a.CollectionNames) -join ', ')"
    }
} catch { Write-Fail $_ }

Write-Section '2. SMS_DeploymentSummary: the software catalog'
$picked = $null
$types = @{ 1 = 'user'; 2 = 'device' }
$intents = @{ 1 = 'Required'; 2 = 'Available'; 3 = 'Simulate' }
try {
    $cols = @{}
    foreach ($c in Invoke-AdminService 'SMS_Collection?$select=CollectionID,Name,CollectionType,MemberCount') {
        $cols[[string]$c.CollectionID] = $c
    }
    Write-Host "  OK  $($cols.Count) collection(s) visible" -ForegroundColor Green
    $select = 'SMS_DeploymentSummary?$select=SoftwareName,CollectionID,CollectionName,FeatureType,DesiredConfigType'
    # The intent column is the one this route may not serve, so it is the one dropped on a retry.
    try { $sum = Invoke-AdminService "$select,DeploymentIntent" }
    catch {
        Write-Host "  with DeploymentIntent: $($_.Exception.Message), retrying without it" -ForegroundColor Yellow
        $sum = Invoke-AdminService $select
    }
    # Same keep rule as the Lens software list: application installs only.
    $apps = @($sum | Where-Object { [int]$_.FeatureType -eq 1 -and [int]$_.DesiredConfigType -eq 1 } |
            ForEach-Object {
                $c = $cols[[string]$_.CollectionID]
                [pscustomobject]@{
                    Software     = [string]$_.SoftwareName
                    CollectionID = [string]$_.CollectionID
                    Collection   = [string]$_.CollectionName
                    Type         = if ($c) { $types[[int]$c.CollectionType] } else { '?' }
                    Members      = if ($c) { [int]$c.MemberCount } else { -1 }
                    Intent       = $intents[[int]$_.DeploymentIntent]
                }
            } | Sort-Object Software, Collection)
    Write-Host "  OK  $($apps.Count) application deployment(s) out of $($sum.Count) rows" -ForegroundColor Green
    if ($apps.Count -eq 0 -and $sum.Count -gt 0) {
        # The keep rule needs both columns, and a route that drops one hides every app.
        $withFeature = @($sum | Where-Object { $null -ne $_.PSObject.Properties['FeatureType'] }).Count
        $withConfig = @($sum | Where-Object { $null -ne $_.PSObject.Properties['DesiredConfigType'] }).Count
        Write-Host "  rows carrying FeatureType: $withFeature   DesiredConfigType: $withConfig" -ForegroundColor Yellow
        Write-Host '  every software name the site returned, unfiltered:' -ForegroundColor Yellow
        $sum | ForEach-Object { [string]$_.SoftwareName } | Sort-Object -Unique | ForEach-Object { "    $_" }
    }
    $byType = $apps | Group-Object Type | ForEach-Object { "$($_.Name) $($_.Count)" }
    Write-Host "  by collection type : $($byType -join ', ')"
    $apps | Format-Table Software, Collection, Type, Members, Intent -AutoSize | Out-String -Width 200 | Write-Host
    Write-Host '  -Software takes one of these, exactly as written:' -ForegroundColor White
    $apps | ForEach-Object { $_.Software } | Sort-Object -Unique | ForEach-Object { "    $_" }
    if ($Software) {
        $hits = @($apps | Where-Object { $_.Software -ieq $Software })
        if ($hits.Count -eq 0) { $hits = @($apps | Where-Object { $_.Software -like "*$Software*" }) }
        if ($hits.Count -gt 1 -and $Collection) {
            $hits = @($hits | Where-Object { $_.CollectionID -ieq $Collection -or $_.Collection -ieq $Collection })
        }
        if ($hits.Count -eq 1) {
            $picked = $hits[0]
            Write-Host ("  picked : '$($picked.Software)' via $($picked.CollectionID) '$($picked.Collection)' " +
                "($($picked.Type), $($picked.Intent))") -ForegroundColor White
        } elseif ($hits.Count -eq 0) {
            Write-Host "  '$Software' matches nothing: copy a name from the list above" -ForegroundColor Yellow
        } else {
            Write-Host "  '$Software' is deployed to $($hits.Count) collections, pass -Collection with one:" `
                       -ForegroundColor Yellow
            $hits | Format-Table CollectionID, Collection, Type, Intent -AutoSize | Out-String -Width 200 | Write-Host
        }
    }
} catch { Write-Fail $_ }

Write-Section '3. The target'
$resourceId = 0
$resourceClass = ''
if ($Target) {
    try {
        $rows = Invoke-AdminService ("SMS_R_System?`$filter=" +
            [uri]::EscapeDataString("Name eq '$Target'") + '&$select=ResourceID,Name,Obsolete')
        $live = @($rows | Where-Object { -not $_.Obsolete })
        if ($live.Count -gt 0) {
            $resourceId = [int]$live[0].ResourceID
            $resourceClass = 'SMS_R_System'
            Write-Host "  device : $Target is ResourceID $resourceId" -ForegroundColor Green
        } else { Write-Err "$Target has no live SMS_R_System record" }
    } catch { Write-Fail $_ }
}
if ($Sam) {
    try {
        $rows = Invoke-AdminService ("SMS_R_User?`$filter=" +
            [uri]::EscapeDataString("endswith(UniqueUserName,'$Sam')") + '&$select=ResourceID,UniqueUserName')
        $exact = @($rows | Where-Object { ($_.UniqueUserName -split '\\')[-1] -ieq $Sam })
        if ($exact.Count -gt 0) {
            $userId = [int]$exact[0].ResourceID
            Write-Host "  user   : $($exact[0].UniqueUserName) is ResourceID $userId" -ForegroundColor Green
            # A user collection takes the user; a device collection keeps the device pinned above.
            if (-not $picked -or $picked.Type -eq 'user') { $resourceId = $userId; $resourceClass = 'SMS_R_User' }
        } else { Write-Err "no SMS_R_User row ends with '$Sam'" }
    } catch { Write-Fail $_ }
}
if ($picked -and $resourceId) {
    try {
        $members = Get-CollectionMember $picked.CollectionID
        $in = @($members | Where-Object { [int]$_.ResourceID -eq $resourceId }).Count -gt 0
        Write-Host ("  membership : $resourceClass $resourceId is " +
            "$(if ($in) { 'ALREADY IN' } else { 'not in' }) $($picked.CollectionID) ($($members.Count) members)")
    } catch { Write-Err "members: $($_.Exception.Message)" }
    # The keyed read expands the lazy CollectionRules, which say how the site fills this collection.
    try {
        $col = Invoke-AdminService "SMS_Collection('$($picked.CollectionID)')" | Select-Object -First 1
        $rules = @($col.CollectionRules)
        Write-Host ("  collection : IsBuiltIn=$($col.IsBuiltIn)  limited to $($col.LimitToCollectionID) " +
            "'$($col.LimitToCollectionName)'  $($rules.Count) rule(s)")
        foreach ($r in $rules) {
            $kind = ([string]$r.'@odata.type') -replace '^#AdminService\.SMS_CollectionRule', ''
            $what = [string]$r.RuleName
            if ($r.QueryExpression) {
                $q = [string]$r.QueryExpression -replace '\s+', ' '
                $what = "'$what' $($q.Substring(0, [Math]::Min(100, $q.Length)))"
            }
            Write-Host "    $kind : $what"
        }
    } catch { Write-Err "collection: $($_.Exception.Message)" }
    # Its security scopes: a role grants Modify on a scope, and this is the pairing a 500 wants.
    try {
        $cats = @{}
        foreach ($c in Invoke-AdminService 'SMS_SecuredCategory?$select=CategoryID,CategoryName') {
            $cats[[string]$c.CategoryID] = [string]$c.CategoryName
        }
        $mem = Invoke-AdminService ("SMS_SecuredCategoryMembership?`$filter=" +
            [uri]::EscapeDataString("ObjectKey eq '$($picked.CollectionID)'") + '&$select=CategoryID')
        $names = @($mem | ForEach-Object { $cats[[string]$_.CategoryID] })
        Write-Host "  scopes     : $($names -join ', ')"
    } catch { Write-Host "  scopes     : not readable ($($_.Exception.Message))" -ForegroundColor Yellow }
}

Write-Section '4. SMS_ClientOperation: what the site already holds'
try {
    $ops = Invoke-AdminService 'SMS_ClientOperation'
    Write-Host "  OK  $($ops.Count) operation row(s)" -ForegroundColor Green
    if ($ops.Count -gt 0) {
        Write-Host "  properties : $(@($ops[0].PSObject.Properties.Name) -join ', ')"
        $ops | Sort-Object ID -Descending | Select-Object -First 3 |
            Format-Table ID, PrimaryActionType, CollectionID, TargetType, State, CreatedBy, RequestedTime -AutoSize |
            Out-String -Width 200 | Write-Host
    }
} catch { Write-Fail $_ }

if (-not ($Push -or $Notify -or $Retract)) {
    Write-Host ''
    Write-Host 'Reads only. Sections 1 to 4 are the decision; -Push, -Notify and -Retract confirm it.' `
               -ForegroundColor DarkGray
} elseif ($Target -ieq $env:COMPUTERNAME -or $Sam -ieq $env:USERNAME) {
    Write-Host "`nrefused: that is the box or account running this, so pass a throwaway one." -ForegroundColor Red
} elseif (($Push -or $Retract) -and -not ($picked -and $resourceId)) {
    Write-Host "`n-Push and -Retract need one catalog app (section 2) and a pinned target (section 3)." `
               -ForegroundColor Red
} elseif ($picked -and $picked.Type -eq 'device' -and $resourceClass -ne 'SMS_R_System' -and ($Push -or $Retract)) {
    Write-Host "`n'$($picked.Collection)' is a device collection, so pass -Target." -ForegroundColor Red
} elseif ($picked -and $picked.Type -eq 'user' -and $resourceClass -ne 'SMS_R_User' -and ($Push -or $Retract)) {
    Write-Host "`n'$($picked.Collection)' is a user collection, so pass -Sam." -ForegroundColor Red
} else {
    $collection = "SMS_Collection('$($picked.CollectionID)')"
    $rule = @{ collectionRule = @{
            '@odata.type'     = '#AdminService.SMS_CollectionRuleDirect'
            ResourceClassName = $resourceClass
            ResourceID        = $resourceId
            RuleName          = if ($Target -and $resourceClass -eq 'SMS_R_System') { $Target } else { $Sam }
        }
    }
    $ruleName = [string]$rule.collectionRule.RuleName
    if ($Push) {
        Write-Section "5. Push: add $resourceClass $resourceId to $($picked.CollectionID)$(if ($Wmi) { ' over WMI' })"
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            if ($Wmi) {
                $p = Connect-Provider -collectionId $picked.CollectionID `
                                      -class $resourceClass `
                                      -id $resourceId `
                                      -name $ruleName
                $out = Invoke-CimMethod -InputObject $p.Collection `
                                        -CimSession $p.Session `
                                        -MethodName AddMembershipRule `
                                        -Arguments @{ collectionRule = $p.Rule }
                Write-Host "  OK  rule added ($($sw.ElapsedMilliseconds) ms), ReturnValue $($out.ReturnValue)" `
                           -ForegroundColor Green
                $null = Invoke-CimMethod -InputObject $p.Collection `
                                         -CimSession $p.Session `
                                         -MethodName RequestRefresh
            } else {
                $r = Invoke-AdminService "$collection/AdminService.AddMembershipRule" $rule
                Write-Host "  OK  rule added ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
                Write-Host "  response : $($r | ConvertTo-Json -Compress -Depth 3)"
                $null = Invoke-AdminService "$collection/AdminService.RequestRefresh" @{}
            }
            Write-Host '  OK  refresh requested' -ForegroundColor Green
            # Membership evaluation is asynchronous, and a direct rule usually lands within seconds.
            $seen = $false
            foreach ($i in 1..6) {
                Start-Sleep -Seconds 5
                $seen = @(Get-CollectionMember $picked.CollectionID |
                        Where-Object { [int]$_.ResourceID -eq $resourceId }).Count -gt 0
                if ($seen) { break }
            }
            if ($seen) {
                Write-Host "  OK  member after $($sw.Elapsed.TotalSeconds.ToString('0'))s" -ForegroundColor Green
            } else {
                Write-Host '  not a member after 30s: check the collection in the console' -ForegroundColor Yellow
            }
        } catch { Write-Fail $_ }
    }
    if ($Notify -and $resourceClass -eq 'SMS_R_System') {
        Write-Section "6. Notify: Download Computer Policy to $Target"
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-AdminService 'SMS_ClientOperation.InitiateClientOperationEx' @{
                Type                = 1
                TargetCollectionID  = $(if ($picked) { $picked.CollectionID } else { 'SMS00001' })
                TargetResourceIDs   = @($resourceId)
                RandomizationWindow = 0
            }
            Write-Host "  OK  ($($sw.ElapsedMilliseconds) ms)" -ForegroundColor Green
            Write-Host "  response : $($r | ConvertTo-Json -Compress -Depth 3)"
            $opId = $r | ForEach-Object { $_.OperationID } | Select-Object -First 1
            if ($opId) {
                $row = Invoke-AdminService "SMS_ClientOperation($opId)"
                Write-Host "  recorded : $($row | Select-Object ID, PrimaryActionType, CollectionID, TargetType, State |
                    ConvertTo-Json -Compress)"
            }
        } catch { Write-Fail $_ }
    } elseif ($Notify) {
        Write-Host "`n-Notify needs -Target: a user has no client to notify." -ForegroundColor Yellow
    }
    if ($Retract) {
        Write-Section ("7. Retract: remove $resourceClass $resourceId from $($picked.CollectionID)" +
            $(if ($Wmi) { ' over WMI' }))
        try {
            if ($Wmi) {
                $p = Connect-Provider -collectionId $picked.CollectionID `
                                      -class $resourceClass `
                                      -id $resourceId `
                                      -name $ruleName
                $null = Invoke-CimMethod -InputObject $p.Collection `
                                         -CimSession $p.Session `
                                         -MethodName DeleteMembershipRule `
                                         -Arguments @{ collectionRule = $p.Rule }
                $null = Invoke-CimMethod -InputObject $p.Collection `
                                         -CimSession $p.Session `
                                         -MethodName RequestRefresh
            } else {
                $null = Invoke-AdminService "$collection/AdminService.DeleteMembershipRule" $rule
                $null = Invoke-AdminService "$collection/AdminService.RequestRefresh" @{}
            }
            Write-Host '  OK  rule removed, refresh requested' -ForegroundColor Green
        } catch { Write-Fail $_ }
    }
}

Write-Host "`nInterpretation:" -ForegroundColor White
Write-Host '  1: no row is you or your groups         -> a nested group grants the reads; the console names it.'
Write-Host '  1: a group row is you                   -> its roles and scopes are the whole grant the app can use.'
Write-Host '  2: apps listed, one collection each     -> the catalog is the Lens software fetch, unfiltered.'
Write-Host '  2: mostly user collections              -> push the person, every device follows, no device pick.'
Write-Host '  2: mostly device collections            -> push the device, the Lens device row is the start.'
Write-Host '  2: Intent column empty                  -> the route drops DeploymentIntent, the message stays generic.'
Write-Host '  3: ALREADY IN                           -> the row shows Pushed instead of a Push button.'
Write-Host '  5: 403                                  -> the role lacks Modify on the collection, ask for it.'
Write-Host '  5: 404 or 405                           -> this route does not call methods, report it.'
Write-Host '  3: a Query rule on an AD group          -> the site fills it from AD, the push may belong in the group.'
Write-Host '  5: 500 Insufficient rights              -> the identity in 1 lacks Modify on the scopes in 3, ask for it.'
Write-Host '  5: 500, -Wmi OK                         -> the REST route is the problem, the push uses the provider.'
Write-Host '  5: 500, -Wmi ERR too                    -> the WMI message is the real one, paste it.'
Write-Host '  5: OK, member within 30s                -> design confirmed: one rule, one refresh per push.'
Write-Host '  6: 403                                  -> the role lacks Notify Resource, the poll delivers it.'
Write-Host '  6: OK, console names the action         -> the push lands in minutes, not an hour.'
