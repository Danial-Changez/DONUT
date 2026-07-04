#Requires -Version 5.1
<#
.SYNOPSIS
    Proves Option A end-to-end: from an ELEVATED (admin-account) context, drop to the
    interactive user and, in that de-elevated child, find the AdminService query shape
    that resolves a user to their WSID - the split DONUT needs (psexec stays admin, the
    SCCM lookup runs as you).

.DESCRIPTION
    Run this "as administrator" (entering your admin account, exactly as you launch
    DONUT). It then:
      1. Records the elevated parent identity (your admin account).
      2. Finds the interactive user (owner of explorer.exe = your regular account).
      3. Spawns a HIDDEN child as that user via Shell.Application ShellExecute (routes
         through explorer -> medium integrity), so the child drops out of elevation.
      4. In the child, reports its identity + integrity AND tries several AdminService
         /wmi/SMS_UserMachineRelationship query shapes, because a raw
         "UniqueUserName eq 'DOMAIN\user'" filter 404s (the domain backslash encodes to
         %5C, which IIS routing rejects). It tries the backslash filter, backslash-free
         function filters (endswith / contains on the SAM), and a page-and-match
         fallback, reporting which returns the mapping.

    PASS = the child was NOT elevated, ran as the interactive user, and at least one
    query returned the user->WSID. That query is what DONUT will use. Read-only.

    MECHANISM NOTE: de-elevation is done with a one-shot scheduled task whose principal
    is the interactive user (LogonType Interactive = their logged-on token, no password;
    RunLevel Limited = de-elevated). This is required because you elevate as a SEPARATE
    admin account - the simpler Shell.Application trick only de-elevates within the SAME
    user, so it left the child in the admin context. DONUT's shipped helper can use this
    same task approach or the CreateProcessWithTokenW token API; the identity drop and
    SCCM access proven here are identical.

.PARAMETER SiteServer
    AdminService host. Default 'sccm01.contoso.com'.

.PARAMETER UserName
    DOMAIN\user to resolve (e.g. 'PRODUCTION\U0073097'). Without it, only the fallback
    query runs (the filter-shape variants need a user to test).

.PARAMETER TimeoutSec
    How long the parent waits for the child's result. Default 60.

.NOTES
    Read-only. Run ELEVATED (as your admin account) so there is something to de-elevate
    FROM. The child runs hidden and silent.

.EXAMPLE
    pwsh -File tools\Test-DeElevatedSccm.ps1 -UserName 'PRODUCTION\U0073097'
#>
[CmdletBinding()]
param(
    [string] $SiteServer = 'sccm01.contoso.com',
    [string] $UserName   = '',
    [int]    $TimeoutSec  = 60
)

$ErrorActionPreference = 'Stop'
function Info([string]$m) { Write-Host "[INFO] $m" -ForegroundColor Gray }
function Pass([string]$m) { Write-Host "[PASS] $m" -ForegroundColor Green }
function Warn([string]$m) { Write-Host "[WARN] $m" -ForegroundColor Yellow }
function Fail([string]$m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

Write-Host ''
Write-Host "De-elevation + SCCM query test  -  AdminService on $SiteServer" -ForegroundColor White

# --- 1. Parent identity + elevation -----------------------------------------------
$meId = [Security.Principal.WindowsIdentity]::GetCurrent()
$parentElevated = ([Security.Principal.WindowsPrincipal]$meId).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info "Parent (this process): $($meId.Name)  (elevated = $parentElevated)"
if (-not $parentElevated) {
    Warn "This process is NOT elevated - the point is to de-elevate FROM an elevated context."
    Warn "Re-run it 'as administrator' (entering your admin account, like you launch DONUT)."
}
if (-not $UserName) {
    Warn "No -UserName given: only the fallback query runs. Pass -UserName 'DOMAIN\user' to test the filter shapes."
}

# --- 2. Interactive user (explorer owner) -----------------------------------------
$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $explorer) {
    Fail "No explorer.exe found - no interactive desktop session to de-elevate into (session 0?)."
    exit 1
}
$owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
$interactiveUser = "$($owner.Domain)\$($owner.User)"
Info "Interactive user (de-elevation target): $interactiveUser"

# --- 3. Shared exchange dir both accounts can read/write --------------------------
# The admin parent's %TEMP% is under its profile (the regular user can't traverse it),
# so use a ProgramData subfolder and grant the interactive user rights on it.
$dir = Join-Path $env:ProgramData ("DONUT\deelev-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir -Force | Out-Null
try {
    $acl = Get-Acl $dir
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($interactiveUser, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $dir -AclObject $acl
} catch {
    Warn "Could not grant $interactiveUser on the exchange folder (the child may fail to write): $($_.Exception.Message)"
}

$childPath  = Join-Path $dir 'child.ps1'
$resultPath = Join-Path $dir 'result.json'
$ok = $false
$taskName = $null

try {
    # --- 4. Child script (runs as the interactive user) ---------------------------
    # Single-quoted here-string: the parent expands nothing. The child gets values from
    # param(); OData keywords are backtick-escaped so the CHILD sees literal $filter/etc.,
    # while ${base}/$sam/$Query are the child's own variables.
    $childBody = @'
param([string]$ResultPath, [string]$SiteServer, [string]$UserName)
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}
$o = [ordered]@{}
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $o.User = $id.Name
    $o.Elevated = ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $o.Integrity = ((whoami /groups) | Select-String 'Mandatory Level' | ForEach-Object { ($_.Line -split '\s{2,}')[0].Trim() }) -join '; '
} catch { $o.IdentityError = $_.Exception.Message }

$base = "https://$SiteServer/AdminService/wmi/SMS_UserMachineRelationship"
$sam = if ($UserName -match '\\') { $UserName.Split('\')[-1] } else { $UserName }

function Invoke-AS([string]$Label, [string]$Query) {
    $r = [ordered]@{ Label = $Label; Ok = $false; Status = 0; Result = '' }
    try {
        $p = @{ Uri = "${base}?$Query"; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
        if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
        $resp = Invoke-RestMethod @p
        $rows = @($resp.value)
        $r.Ok = $true; $r.Status = 200
        $r.Result = (($rows | ForEach-Object { "$($_.UniqueUserName)=$($_.ResourceName)" }) -join ', ')
    } catch {
        if ($_.Exception.Response) { $r.Status = [int]$_.Exception.Response.StatusCode }
        $r.Result = $_.Exception.Message
    }
    return [pscustomobject]$r
}

$variants = @()
if ($UserName) {
    $variants += Invoke-AS 'eq+backslash' ("`$filter=" + [uri]::EscapeDataString("UniqueUserName eq '$UserName'") + "&`$select=UniqueUserName,ResourceName")
    $variants += Invoke-AS 'endswith'     ("`$filter=" + [uri]::EscapeDataString("endswith(UniqueUserName,'$sam')") + "&`$select=UniqueUserName,ResourceName")
    $variants += Invoke-AS 'contains'     ("`$filter=" + [uri]::EscapeDataString("contains(UniqueUserName,'$sam')") + "&`$select=UniqueUserName,ResourceName")
}

# Guaranteed fallback: page server-side ($top is known to work), match client-side.
$fb = [ordered]@{ Label = 'top+client'; Ok = $false; Status = 0; Result = '' }
try {
    $p = @{ Uri = "${base}?`$top=1000&`$select=UniqueUserName,ResourceName"; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    $resp = Invoke-RestMethod @p
    $fb.Ok = $true; $fb.Status = 200
    if ($sam) {
        $hit = @($resp.value) | Where-Object { $_.UniqueUserName -like "*$sam" }
        $fb.Result = (($hit | ForEach-Object { "$($_.UniqueUserName)=$($_.ResourceName)" }) -join ', ')
    } else {
        $fb.Result = "(page of $(@($resp.value).Count) rows; pass -UserName to match)"
    }
} catch {
    if ($_.Exception.Response) { $fb.Status = [int]$_.Exception.Response.StatusCode }
    $fb.Result = $_.Exception.Message
}
$variants += [pscustomobject]$fb

$o.Variants = $variants
$o.Finished = (Get-Date).ToString('o')
$o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@
    Set-Content -LiteralPath $childPath -Value $childBody -Encoding UTF8

    # --- 5. Launch as the interactive user via a de-elevated one-shot task ---------
    # A scheduled task whose principal is the interactive user (LogonType Interactive =
    # their logged-on token, no password; RunLevel Limited = de-elevated) - this crosses
    # the account boundary that Shell.Application could not (you elevate as a separate
    # admin account, so the shell-COM child stayed elevated in the admin context).
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath) { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwshPath) { throw "Could not resolve the host PowerShell (pwsh.exe) path to relaunch." }

    Info "Registering a de-elevated one-shot task as $interactiveUser (Interactive token, RunLevel Limited)..."
    $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ResultPath "{1}" -SiteServer "{2}" -UserName "{3}"' -f $childPath, $resultPath, $SiteServer, $UserName
    $taskName  = 'DONUT-DeElevTest-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $action    = New-ScheduledTaskAction -Execute $pwshPath -Argument $argline
    $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $task      = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
    Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

    # --- 6. Wait for the child's result -------------------------------------------
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $resultPath)) {
        Warn "No result within $TimeoutSec s. The de-elevated child never wrote back - likely the"
        Warn "task couldn't start as $interactiveUser (not logged on?), or the exchange-folder grant failed."
        Fail "De-elevation could not be confirmed."
        return
    }
    Start-Sleep -Milliseconds 300   # let the write settle
    $res = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json

    # --- 7. Verdict ---------------------------------------------------------------
    Write-Host ''
    Write-Host '== Result ==' -ForegroundColor Cyan
    Info "Child ran as : $($res.User)  (elevated = $($res.Elevated))"
    Info "Child integ. : $($res.Integrity)"
    $deElevated = ($res.Elevated -eq $false)
    if ($deElevated) { Pass "De-elevation confirmed - child is medium integrity, running as the interactive user." }
    else { Warn "Child came back ELEVATED - privileges were not dropped as expected." }

    Write-Host ''
    Write-Host '== AdminService query shapes (tried inside the de-elevated child) ==' -ForegroundColor Cyan
    $winner = $null
    foreach ($v in $res.Variants) {
        if ($v.Ok -and $v.Result -and $v.Result -notmatch '^\(page of') { $tag = 'PASS'; $col = 'Green'; if (-not $winner) { $winner = $v } }
        elseif ($v.Ok) { $tag = 'EMPTY'; $col = 'Yellow' }
        else { $tag = "FAIL $($v.Status)"; $col = 'Red' }
        Write-Host ("  [{0,-7}] {1,-13} {2}" -f $tag, $v.Label, $v.Result) -ForegroundColor $col
    }

    Write-Host ''
    if ($winner) {
        Pass "Working query for DONUT: '$($winner.Label)'  ->  $($winner.Result)"
        $ok = $deElevated
    } else {
        Warn "No query returned the mapping - see the statuses above."
    }
}
finally {
    if ($taskName) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($ok) {
    Pass "OPTION A VALIDATED: DONUT can stay elevated for psexec and run the SCCM lookup in a de-elevated child."
    exit 0
} else {
    Warn "Option A not fully confirmed - see the lines above."
    exit 1
}
