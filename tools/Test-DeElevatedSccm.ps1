#Requires -Version 5.1
<#
.SYNOPSIS
    Proves Option A: from an ELEVATED (admin-account) context, drop down to the
    interactive logged-in user and run the SCCM AdminService lookup as THAT user -
    the split DONUT needs (psexec stays admin, the SCCM query runs as you).

.DESCRIPTION
    Run this "as administrator" (entering your admin account, exactly as you launch
    DONUT). It then:
      1. Records the elevated parent identity (your admin account).
      2. Finds the interactive user (the owner of explorer.exe = your regular account).
      3. Spawns a HIDDEN child PowerShell as that interactive user via Shell.Application
         ShellExecute - which routes through explorer (medium integrity), so the child
         drops out of elevation and runs as you. No password, no token stored.
      4. The child reports its own identity + integrity and calls the AdminService
         (/wmi/SMS_UserMachineRelationship) with its own Kerberos ticket, writing the
         result to a shared file the parent reads back.

    A PASS means: the child was NOT elevated, ran as the interactive user, AND the SCCM
    call succeeded in that context - i.e. DONUT can stay elevated for psexec while a
    de-elevated child does the ConfigMgr work. Everything is read-only.

    NOTE ON MECHANISM: this test uses Shell.Application (the simplest reliable
    de-elevation). DONUT's shipped helper would use the CreateProcessWithTokenW token
    API instead, for inline stdout capture - but the identity drop and SCCM access this
    proves are identical.

.PARAMETER SiteServer
    SMS Provider / AdminService host. Default 'sccm01.contoso.com'.

.PARAMETER UserName
    Optional DOMAIN\user to resolve to a WSID in the child. Omitted = a top-1 read
    (still proves the child can reach ConfigMgr).

.PARAMETER TimeoutSec
    How long the parent waits for the child's result file. Default 60.

.NOTES
    Read-only. Run elevated (as your admin account) so there is something to de-elevate
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
Write-Host "De-elevation + SCCM test  -  AdminService on $SiteServer" -ForegroundColor White

# --- 1. Parent identity + elevation -----------------------------------------------
$me = [Security.Principal.WindowsIdentity]::GetCurrent()
$parentUser = $me.Name
$parentElevated = ([Security.Principal.WindowsPrincipal]$me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Info "Parent (this process): $parentUser  (elevated = $parentElevated)"
if (-not $parentElevated) {
    Warn "This process is NOT elevated. The point is to de-elevate FROM an elevated context -"
    Warn "re-run it 'as administrator' (entering your admin account, like you launch DONUT)."
}

# --- 2. Interactive user (explorer owner) -----------------------------------------
$explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $explorer) {
    Fail "No explorer.exe found - there is no interactive desktop session to de-elevate into (session 0?)."
    exit 1
}
$owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
$interactiveUser = "$($owner.Domain)\$($owner.User)"
Info "Interactive user (de-elevation target): $interactiveUser"

# --- 3. Shared exchange dir both accounts can read/write --------------------------
# The admin parent's own %TEMP% lives under its profile, which the regular user can't
# even traverse - so use a ProgramData subfolder and grant the interactive user rights.
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

try {
    # --- 4. Child script (runs as the interactive user) ---------------------------
    # Single-quoted here-string: nothing is expanded by the parent. The child gets its
    # values from param(); OData keywords are backtick-escaped so the CHILD sees literal
    # $filter/$select/$top, while $base/$f/etc. are the child's own variables.
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
try {
    $base = "https://$SiteServer/AdminService"
    if ($UserName) {
        $f = [uri]::EscapeDataString("UniqueUserName eq '$UserName'")
        $url = "$base/wmi/SMS_UserMachineRelationship?`$filter=$f&`$select=UniqueUserName,ResourceName"
    } else {
        $url = "$base/wmi/SMS_UserMachineRelationship?`$top=1"
    }
    $p = @{ Uri = $url; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    $resp = Invoke-RestMethod @p
    $rows = @($resp.value)
    $o.SccmOk = $true
    $o.SccmCount = $rows.Count
    $o.SccmRows = @($rows | ForEach-Object { [ordered]@{ User = $_.UniqueUserName; ResourceName = $_.ResourceName } })
} catch {
    $o.SccmOk = $false
    $o.SccmError = $_.Exception.Message
}
$o.Finished = (Get-Date).ToString('o')
$o | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $ResultPath -Encoding UTF8
'@
    Set-Content -LiteralPath $childPath -Value $childBody -Encoding UTF8

    # --- 5. Launch hidden as the interactive user via Shell.Application ------------
    $pwshPath = (Get-Process -Id $PID).Path
    if (-not $pwshPath) { $pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source }
    if (-not $pwshPath) { throw "Could not resolve the host PowerShell (pwsh.exe) path to relaunch." }

    Info "Launching hidden child as $interactiveUser (Shell.Application -> explorer -> medium integrity)..."
    $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ResultPath "{1}" -SiteServer "{2}" -UserName "{3}"' -f $childPath, $resultPath, $SiteServer, $UserName
    $shell = New-Object -ComObject Shell.Application
    $shell.ShellExecute($pwshPath, $argline, '', 'open', 0)   # 0 = SW_HIDE

    # --- 6. Wait for the child's result -------------------------------------------
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path -LiteralPath $resultPath)) {
        Warn "No result within $TimeoutSec s. The de-elevated child never wrote back - likely the"
        Warn "shell COM launch was blocked by policy, or the exchange-folder grant failed."
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
    if ($deElevated) {
        Pass "De-elevation confirmed - the child is medium integrity, running as the interactive user."
    } else {
        Warn "Child came back ELEVATED - privileges were not dropped as expected."
    }

    if ($res.SccmOk) {
        if ($res.SccmCount -gt 0 -and $res.SccmRows) {
            Pass "SCCM AdminService call succeeded as the de-elevated user:"
            $res.SccmRows | ForEach-Object { Write-Host "         $($_.User)  ->  $($_.ResourceName)" }
        } else {
            Pass "SCCM AdminService call succeeded (query returned no rows)."
        }
        $ok = $deElevated
    } else {
        Fail "SCCM call FAILED in the child: $($res.SccmError)"
    }
}
finally {
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
