#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only probe of what your CURRENT account can do against Configuration
    Manager - run it as your regular (non-elevated) user to see whether DONUT
    could drive remote work through SCCM instead of psexec/CIM + an admin account.

.DESCRIPTION
    Checks, in order and independently (one failure never aborts the rest):
      1. Identity + elevation      - confirms you are running as yourself, NOT admin.
      2. Active Directory          - a light LDAP RootDSE bind (the user finder needs this).
      3. ConfigMgr console module  - imports ConfigurationManager.psd1 and connects the
                                     site PSDrive (the "official cmdlet" path).
      4. SMS Provider WMI          - reads root\SMS\site_<code> over DCOM: device records,
                                     the user->device (WSID) mapping, and Run Scripts.
      5. AdminService REST         - the headless driver: GETs the OData/WMI endpoints as
                                     you, over HTTPS, so DONUT could run without a console.
      6. Live CMPivot (optional)   - with -TestDevice, runs a real CMPivot query end-to-end
                                     (this is the "systeminfo without admin" primitive).

    Everything is READ-ONLY. Nothing is deployed, changed, or run on any target
    except the optional CMPivot query (a non-mutating inventory read).

    At the end it prints a capability matrix and what each result means for DONUT.

.PARAMETER SiteCode
    ConfigMgr 3-char site code (also the site PSDrive name). Default 'TPM'.

.PARAMETER SiteServer
    SMS Provider / site server FQDN, used for WMI and the AdminService base URL.
    Default 'sccm01.contoso.com'.

.PARAMETER UserName
    Optional DOMAIN\user to resolve to a workstation via the user-device mapping.
    When omitted, the mapping is only schema/count-checked (no specific user).

.PARAMETER TestDevice
    Optional device (computer) name to run a live CMPivot query against, proving the
    real-time remote-read path works as your account. Omitted = skipped.

.PARAMETER SkipConsoleModule
    Skip the ConfigurationManager module import + PSDrive connect (section 3). The
    WMI (4) and AdminService (5) probes are what matter for headless driving anyway.

.NOTES
    Standalone + read-only + dependency-light. Cert validation is bypassed for the
    AdminService probe only (diagnostic convenience; note it if that surprises you).
    Run from a normal PowerShell window as your regular user - do NOT elevate.

.EXAMPLE
    pwsh -File tools\Confirm-SccmCapabilities.ps1

.EXAMPLE
    pwsh -File tools\Confirm-SccmCapabilities.ps1 -UserName 'CORP\jdoe' -TestDevice 'WSID12345'
#>
[CmdletBinding()]
param(
    [string] $SiteCode   = 'TPM',
    [string] $SiteServer  = 'sccm01.contoso.com',
    [string] $UserName    = '',
    [string] $TestDevice  = '',
    [switch] $SkipConsoleModule
)

$ErrorActionPreference = 'Continue'
$Namespace = "root\SMS\site_$SiteCode"
$AdminBase = "https://$SiteServer/AdminService"
$script:Summary = [System.Collections.Generic.List[object]]::new()

# --- output helpers ---------------------------------------------------------------

function Write-Section([string]$Title) {
    Write-Host ''
    Write-Host "== $Title " -ForegroundColor Cyan -NoNewline
    Write-Host ('=' * [Math]::Max(0, 74 - $Title.Length)) -ForegroundColor DarkCyan
}

# Prints a colored [STATUS] line and records it for the closing matrix.
function Add-Result([string]$Capability, [string]$Status, [string]$Detail) {
    $color = switch ($Status) {
        'PASS' { 'Green' }; 'FAIL' { 'Red' }; 'WARN' { 'Yellow' }
        'SKIP' { 'DarkGray' }; default { 'Gray' }
    }
    Write-Host ("  [{0,-4}] " -f $Status) -ForegroundColor $color -NoNewline
    Write-Host $Detail
    $script:Summary.Add([pscustomobject]@{ Capability = $Capability; Status = $Status; Detail = $Detail })
}

# Invoke-RestMethod against the AdminService as the current user (Kerberos/Negotiate),
# tolerating the site's PKI/self-signed cert - editions differ in how they skip it.
function Invoke-AdminService {
    param([string]$Url, [string]$Method = 'GET', $Body = $null)
    $p = @{ Uri = $Url; Method = $Method; UseDefaultCredentials = $true; ErrorAction = 'Stop' }
    if ($null -ne $Body) { $p.Body = ($Body | ConvertTo-Json -Depth 6); $p.ContentType = 'application/json' }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $p.SkipCertificateCheck = $true }
    return Invoke-RestMethod @p
}

# On Windows PowerShell 5.1, -SkipCertificateCheck doesn't exist: relax TLS + cert
# validation process-wide (diagnostic only; the PS7 path uses the per-call switch).
if ($PSVersionTable.PSVersion.Major -lt 6) {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        [Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    } catch { }
}

Write-Host ''
Write-Host "SCCM capability probe  -  site $SiteCode via $SiteServer" -ForegroundColor White
Write-Host "Read-only. Run this as your REGULAR user (do not elevate)." -ForegroundColor DarkGray

# --- 1. Identity + elevation ------------------------------------------------------

Write-Section 'Identity & elevation'
try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]$id
    $elevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Add-Result 'Identity' 'INFO' "Running as $($id.Name)"
    if ($elevated) {
        Add-Result 'Elevation' 'WARN' 'This process IS elevated/admin - re-run as your plain user to prove SCCM works without it.'
    } else {
        Add-Result 'Elevation' 'PASS' 'Not elevated - exactly how the SCCM path is meant to run.'
    }
} catch {
    Add-Result 'Identity' 'FAIL' "Could not read the current identity: $($_.Exception.Message)"
}

# --- 2. Active Directory ----------------------------------------------------------

Write-Section 'Active Directory'
try {
    $rootDse = [ADSI]'LDAP://RootDSE'
    $nc = [string]$rootDse.defaultNamingContext
    if ($nc) { Add-Result 'AD read' 'PASS' "Bound to the domain ($nc)." }
    else { Add-Result 'AD read' 'WARN' 'RootDSE bound but returned no naming context.' }
} catch {
    Add-Result 'AD read' 'FAIL' "LDAP bind failed (domain-joined?): $($_.Exception.Message)"
}

# --- 3. ConfigMgr console module + site PSDrive -----------------------------------

Write-Section 'ConfigMgr console module (official cmdlet path)'
if ($SkipConsoleModule) {
    Add-Result 'CM module' 'SKIP' '-SkipConsoleModule was set.'
} else {
    $modulePath = $null
    if ($env:SMS_ADMIN_UI_PATH) {
        $modulePath = Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'
    }
    if (-not $modulePath -or -not (Test-Path $modulePath)) {
        Add-Result 'CM module' 'WARN' 'ConfigurationManager.psd1 not found (console not installed here?). The WMI + AdminService paths below do not need it.'
    } else {
        try {
            Import-Module $modulePath -ErrorAction Stop
            Add-Result 'CM module' 'PASS' "Imported $modulePath"
            if (-not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
                New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer -Description 'DONUT probe' -ErrorAction Stop | Out-Null
            }
            Push-Location "$($SiteCode):" -ErrorAction Stop
            try {
                $site = Get-CMSite -ErrorAction Stop | Select-Object -First 1
                Add-Result 'CM site connect' 'PASS' "Connected: $($site.SiteName) [$($site.SiteCode)]"
            } finally { Pop-Location }
        } catch {
            Add-Result 'CM site connect' 'FAIL' "Module/PSDrive connect failed: $($_.Exception.Message)"
        }
    }
}

# --- 4. SMS Provider WMI (root\SMS\site_<code>) -----------------------------------

Write-Section "SMS Provider WMI ($Namespace on $SiteServer)"
$cim = $null
try {
    $opt = New-CimSessionOption -Protocol Dcom
    $cim = New-CimSession -ComputerName $SiteServer -SessionOption $opt -OperationTimeoutSec 20 -ErrorAction Stop
    Add-Result 'Provider DCOM' 'PASS' 'Opened a DCOM CIM session to the SMS Provider.'
} catch {
    Add-Result 'Provider DCOM' 'FAIL' "Could not open a CIM session (RPC/135 blocked or no rights): $($_.Exception.Message)"
}

if ($cim) {
    # Device records - proves you can read the provider at all.
    try {
        $sys = Get-CimInstance -CimSession $cim -Namespace $Namespace -Query 'SELECT ResourceID FROM SMS_R_System' -ErrorAction Stop
        Add-Result 'Device inventory read' 'PASS' "SMS_R_System readable ($(@($sys).Count) device records visible)."
    } catch {
        Add-Result 'Device inventory read' 'FAIL' "SMS_R_System query failed: $($_.Exception.Message)"
    }

    # The user -> workstation mapping you actually want.
    try {
        if ($UserName) {
            $q = "SELECT UniqueUserName, ResourceName FROM SMS_UserMachineRelationship WHERE UniqueUserName='$UserName'"
            $rel = @(Get-CimInstance -CimSession $cim -Namespace $Namespace -Query $q -ErrorAction Stop)
            if ($rel.Count -gt 0) {
                $machines = ($rel | ForEach-Object { $_.ResourceName } | Where-Object { $_ }) -join ', '
                Add-Result 'User->WSID lookup' 'PASS' "$UserName maps to: $machines"
            } else {
                Add-Result 'User->WSID lookup' 'WARN' "No affinity rows for '$UserName' (unmapped user, or affinity not populated). Try a known user, or fall back to SMS_R_System.LastLogonUserName."
            }
        } else {
            $rel = @(Get-CimInstance -CimSession $cim -Namespace $Namespace -Query 'SELECT UniqueUserName, ResourceName FROM SMS_UserMachineRelationship' -ErrorAction Stop)
            Add-Result 'User->WSID lookup' 'PASS' "SMS_UserMachineRelationship readable ($($rel.Count) mappings). Re-run with -UserName 'DOMAIN\user' to resolve a specific one."
        }
    } catch {
        Add-Result 'User->WSID lookup' 'FAIL' "SMS_UserMachineRelationship query failed: $($_.Exception.Message)"
    }

    # Run Scripts read access - a proxy for the Run Scripts RBAC (execution needs more,
    # but if you can't even see the scripts you almost certainly can't run them).
    try {
        $scripts = @(Get-CimInstance -CimSession $cim -Namespace $Namespace -Query 'SELECT ScriptName, ApprovalState FROM SMS_Scripts' -ErrorAction Stop)
        $approved = @($scripts | Where-Object { $_.ApprovalState -eq 3 }).Count
        Add-Result 'Run Scripts read' 'PASS' "SMS_Scripts readable ($($scripts.Count) scripts, $approved approved). Running still needs the Run Script securable on a collection."
    } catch {
        Add-Result 'Run Scripts read' 'WARN' "Can't read SMS_Scripts (feature off or no Scripts RBAC): $($_.Exception.Message)"
    }

    Remove-CimSession -CimSession $cim -ErrorAction SilentlyContinue
}

# --- 5. AdminService REST (the headless driver) -----------------------------------

Write-Section "AdminService REST ($AdminBase)"
$adminOk = $false
try {
    $dev = Invoke-AdminService "$AdminBase/v1.0/Device?`$top=1"
    $adminOk = $true
    Add-Result 'AdminService reachable' 'PASS' 'GET /v1.0/Device returned data - AdminService is up and authenticated you (Kerberos, no admin account).'
} catch {
    $msg = $_.Exception.Message
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    if ($status -eq 401 -or $status -eq 403) {
        Add-Result 'AdminService reachable' 'WARN' "Reached the AdminService but got $status - it's up, but your account lacks the RBAC for this call."
    } else {
        Add-Result 'AdminService reachable' 'FAIL' "GET /v1.0/Device failed: $msg"
    }
}
if ($adminOk) {
    try {
        Invoke-AdminService "$AdminBase/wmi/SMS_UserMachineRelationship?`$top=1" | Out-Null
        Add-Result 'AdminService WMI endpoint' 'PASS' '/wmi/SMS_UserMachineRelationship readable - the user->WSID lookup works headless over REST too.'
    } catch {
        Add-Result 'AdminService WMI endpoint' 'WARN' "/wmi endpoint read failed: $($_.Exception.Message)"
    }
}

# --- 6. Live CMPivot (optional, real-time remote read) ----------------------------

Write-Section 'Live CMPivot (real-time remote read, no admin account)'
if (-not $TestDevice) {
    Add-Result 'CMPivot live' 'SKIP' "Pass -TestDevice '<name>' to run a real CMPivot query end-to-end."
} elseif (-not $adminOk) {
    Add-Result 'CMPivot live' 'SKIP' 'AdminService was unreachable above, so CMPivot cannot be tested.'
} else {
    try {
        $lookup = Invoke-AdminService "$AdminBase/wmi/SMS_R_System?`$filter=Name eq '$TestDevice'&`$select=ResourceId,Name"
        $rid = @($lookup.value)[0].ResourceId
        if (-not $rid) { throw "device '$TestDevice' not found in SMS_R_System" }

        $op = Invoke-AdminService "$AdminBase/v1.0/Device($rid)/AdminService.RunCMPivot" 'POST' @{ InventoryQuery = 'OperatingSystem' }
        $opId = $op.OperationId
        if (-not $opId) { throw 'RunCMPivot returned no OperationId' }
        Add-Result 'CMPivot dispatch' 'PASS' "Queued CMPivot on $TestDevice (ResourceId $rid, OperationId $opId). Polling for the result..."

        $result = $null
        $deadline = (Get-Date).AddSeconds(90)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            try {
                $r = Invoke-AdminService "$AdminBase/v1.0/Device($rid)/AdminService.CMPivotResult(OperationId=$opId)"
                if ($r) { $result = $r; break }
            } catch { }   # 404/202 until the client answers; keep polling
        }
        if ($result) {
            Add-Result 'CMPivot live' 'PASS' "CMPivot returned live data from $TestDevice - real-time remote read works as your account, no admin needed."
        } else {
            Add-Result 'CMPivot live' 'WARN' "Dispatch worked but no result within 90s (client offline/slow). The RBAC + path are proven; the target just didn't answer in time."
        }
    } catch {
        Add-Result 'CMPivot live' 'FAIL' "CMPivot test failed: $($_.Exception.Message)"
    }
}

# --- Summary + what it means for DONUT --------------------------------------------

Write-Section 'Summary'
$script:Summary | Format-Table -AutoSize Capability, Status, Detail | Out-Host

Write-Host ''
Write-Host 'What this means for DONUT:' -ForegroundColor White
Write-Host '  - User->WSID lookup PASS (WMI or AdminService): the AD-finder user->workstation'
Write-Host '    link can run headless as your regular account - no admin, no token tricks.'
Write-Host '  - AdminService reachable PASS: DONUT can drive SCCM (Run Scripts / CMPivot) over'
Write-Host '    REST as you, so remote work need not go through psexec + the admin account.'
Write-Host '  - CMPivot live PASS: real-time inventory reads (a systeminfo replacement) without'
Write-Host '    being a local admin on the target.'
Write-Host '  - Run Scripts read PASS but you lack the Run Script securable: reads work now;'
Write-Host '    executing dcu-cli via SCCM would need that RBAC role (a ConfigMgr grant, not a'
Write-Host '    Windows admin one).'
Write-Host ''
