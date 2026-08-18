#Requires -Version 5.1
<#
.SYNOPSIS
    Probes whether the three RSAT write operations would work over plain
    System.DirectoryServices, without performing any of them.

.DESCRIPTION
    Settles the one open question behind dropping the RSAT ActiveDirectory module.
    Unlock-ADAccount and Set-ADUser map to attribute writes on lockoutTime and
    pwdLastSet; Set-ADAccountPassword maps to IADsUser::SetPassword, which needs a
    secure channel and tries LDAPS, then Kerberos set-password, then NetUserSetInfo.
    Whether those succeed comes down to two things a read can settle: a route that
    answers, and the rights on the account.

    Run as the account that performs resets today, from a box that reaches the DC.

      1. Target: the account, the identity probing it, and its current state.
      2. Routes: the ports each SetPassword fallback needs, with a real TLS
         handshake on 636 rather than a bare connect, since a listening port with
         an unusable certificate is the case that matters.
      3. Binds: binds the DN two ways over, varying the host form and how the
         AuthenticationTypes reach the entry, since passing them to the constructor
         alongside a null user is not the same as setting them afterwards, and the
         plain one-argument form is what ActiveDirectoryService already uses.
      4. Rights: the caller's own ACEs on the account - the Reset Password extended
         right, and write access to the two attributes - resolved through the schema
         so an attribute-scoped grant is not mistaken for a blanket one.

    Sections 1 to 4 change nothing. Section 5 exists only for a final confirmation
    on a throwaway account and runs only with -WriteTest.

.PARAMETER Sam
    sAMAccountName to probe. Reads only, unless -WriteTest is passed.

.PARAMETER Domain
    AD DNS domain to search. Defaults to this session's domain.

.PARAMETER Dc
    Domain controller to bind. Defaults to this session's logon server.

.PARAMETER WriteTest
    Optional final confirmation, and not needed to decide: performs the writes and
    reports SetPassword per bind mode. DESTRUCTIVE - it sets a random password on
    -Sam and does not tell you what it was. Refused when -Sam is the account
    running the probe.

.EXAMPLE
    pwsh -File tools\Probe-AdWrite.ps1 -Sam someuser
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Sam,
    [string] $Domain = '',
    [string] $Dc = '',
    [switch] $WriteTest
)

Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

# Schema GUID of the Reset Password extended right.
$script:ResetPasswordRight = [guid]'00299570-246d-11d0-a768-00aa006e0529'

# Host form and how the auth flags are applied vary separately. See .DESCRIPTION.
$script:BindModes = @(
    @{ Name = 'domain, no auth argument'; Via = 'domain'; Style = 'default' }
    @{ Name = 'domain, auth set after'; Via = 'domain'; Style = 'property'; Auth = 'Secure, Sealing, Signing' }
    @{ Name = 'domain, auth in constructor'; Via = 'domain'; Style = 'ctor'; Auth = 'Secure, Sealing, Signing' }
    @{ Name = 'domain, SSL set after'; Via = 'domain'; Style = 'property'; Auth = 'Secure, SecureSocketsLayer' }
    @{ Name = 'serverless, no auth argument'; Via = ''; Style = 'default' }
    @{ Name = 'dc, no auth argument'; Via = 'dc'; Style = 'default' }
)

$script:Routes = @(
    @{ Port = 389; Needs = 'the two attribute writes' }
    @{ Port = 636; Needs = "SetPassword's first choice (LDAPS)" }
    @{ Port = 464; Needs = 'its Kerberos set-password fallback' }
    @{ Port = 445; Needs = 'its NetUserSetInfo fallback' }
)

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host $title -ForegroundColor Cyan
}

function Write-Result([string]$label, [string]$value, [string]$colour) {
    Write-Host ("  {0,-30} {1}" -f $label, $value) -ForegroundColor $colour
}

# PowerShell wraps a failed bind's COM error twice, and the HRESULT names it exactly.
function Resolve-Reason($record) {
    $ex = $record.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    $code = if ($ex.HResult) { ' (0x{0:X8})' -f $ex.HResult } else { '' }
    return "$($ex.Message.Trim())$code"
}

function Close-Bind($entry) {
    if ($null -ne $entry) { try { $entry.Dispose() } catch { } }
}

function Get-BindPath([string]$dn, [hashtable]$mode) {
    $prefix = switch ($mode.Via) {
        'domain' { "$Domain/" }
        'dc' { "$Dc/" }
        default { '' }
    }
    return "LDAP://$prefix$dn"
}

function New-Bind([string]$dn, [hashtable]$mode) {
    $path = Get-BindPath $dn $mode
    if ($mode.Style -eq 'ctor') {
        $auth = [System.DirectoryServices.AuthenticationTypes]$mode.Auth
        return New-Object System.DirectoryServices.DirectoryEntry($path, $null, $null, $auth)
    }
    $entry = New-Object System.DirectoryServices.DirectoryEntry($path)
    if ($mode.Style -eq 'property') {
        $entry.AuthenticationType = [System.DirectoryServices.AuthenticationTypes]$mode.Auth
    }
    return $entry
}

function Test-Port([int]$port) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        if ($client.ConnectAsync($Dc, $port).Wait(3000)) { return '' }
        return 'no answer within 3s'
    } catch {
        return (Resolve-Reason $_)
    } finally {
        $client.Dispose()
    }
}

# A listening 636 with a certificate ADSI will not accept is the case a connect misses.
function Test-SecureLdap {
    $client = New-Object System.Net.Sockets.TcpClient
    $ssl = $null
    try {
        if (-not $client.ConnectAsync($Dc, 636).Wait(3000)) { return 'no answer within 3s' }
        $accept = [System.Net.Security.RemoteCertificateValidationCallback] { return $true }
        $ssl = New-Object System.Net.Security.SslStream($client.GetStream(), $false, $accept)
        $ssl.AuthenticateAsClient($Dc)
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]$ssl.RemoteCertificate
        $chain = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        $trusted = $chain.Build($cert)
        $expiry = $cert.NotAfter.ToString('yyyy-MM-dd')
        if (-not $trusted) { return "handshake ok but the chain does not validate (expires $expiry)" }
        return "handshake ok, chain valid, expires $expiry"
    } catch {
        return (Resolve-Reason $_)
    } finally {
        if ($ssl) { $ssl.Dispose() }
        $client.Dispose()
    }
}

# 20 chars across four classes, so no site policy rejects the probe for complexity.
function New-ProbePassword {
    $sets = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnpqrstuvwxyz',
        '23456789',
        '!@#$%^&*-_=+'
    )
    $chars = foreach ($i in 0..19) { $set = $sets[$i % 4]; $set[(Get-Random -Maximum $set.Length)] }
    return -join ($chars | Sort-Object { Get-Random })
}

# GetComputerDomain reads domain membership rather than the token, so an elevated
# session as a local or cross-domain admin resolves the same as the desktop user's.
if (-not $Domain -or -not $Dc) {
    try {
        $computerDomain = [System.DirectoryServices.ActiveDirectory.Domain]::GetComputerDomain()
        if (-not $Domain) { $Domain = $computerDomain.Name }
        if (-not $Dc) { $Dc = $computerDomain.FindDomainController().Name }
    } catch {
        if (-not $Domain) { $Domain = $env:USERDNSDOMAIN }
        if (-not $Dc) { $Dc = ($env:LOGONSERVER -replace '^\\\\', '') }
    }
}
if (-not $Domain -or -not $Dc) {
    Write-Host "Could not resolve a domain and DC (domain='$Domain', dc='$Dc'). Pass -Domain and -Dc." `
               -ForegroundColor Red
    return
}

$script:RootPath = "LDAP://$Domain/DC=$($Domain -replace '\.', ',DC=')"

function New-Searcher([string]$path) {
    $root = New-Object System.DirectoryServices.DirectoryEntry($path)
    return New-Object System.DirectoryServices.DirectorySearcher($root)
}

# lockoutTime and pwdLastSet are named in an ACE by schema GUID, never by name.
function Get-AttributeGuid([string]$ldapName) {
    try {
        $rootDse = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Domain/RootDSE")
        $schema = [string]$rootDse.Properties['schemaNamingContext'].Value
        $finder = New-Searcher "LDAP://$Domain/$schema"
        $finder.Filter = "(lDAPDisplayName=$ldapName)"
        [void]$finder.PropertiesToLoad.Add('schemaIDGUID')
        $row = $finder.FindOne()
        if (-not $row) { return $null }
        return [guid][byte[]]$row.Properties['schemaidguid'][0]
    } catch {
        return $null
    }
}

# --- 1. Target -------------------------------------------------------------

Write-Section '1. Target account'

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([System.Security.Principal.WindowsPrincipal]::new($me)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Result 'running as' "$($me.Name)$(if ($elevated) { '  (elevated)' })" 'Gray'
Write-Result 'domain / dc' "$Domain  /  $Dc" 'Gray'

$searcher = New-Searcher $script:RootPath
$searcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$Sam))"
foreach ($p in @('distinguishedName', 'lockoutTime', 'pwdLastSet', 'userAccountControl')) {
    [void]$searcher.PropertiesToLoad.Add($p)
}

$hit = $null
try {
    $hit = $searcher.FindOne()
} catch {
    Write-Result 'search' (Resolve-Reason $_) 'Red'
    return
}
if (-not $hit) {
    Write-Result 'account' "NOT FOUND ($Sam in $Domain)" 'Red'
    return
}

$dn = [string]$hit.Properties['distinguishedname'][0]
$lockoutTime = if ($hit.Properties['lockouttime'].Count) { [int64]$hit.Properties['lockouttime'][0] } else { 0 }
$pwdLastSet = if ($hit.Properties['pwdlastset'].Count) { [int64]$hit.Properties['pwdlastset'][0] } else { 0 }

Write-Result 'dn' $dn 'Gray'
Write-Result 'lockoutTime' "$lockoutTime$(if ($lockoutTime -ne 0) { '  (locked)' })" 'Gray'
Write-Result 'pwdLastSet' "$pwdLastSet$(if ($pwdLastSet -eq 0) { '  (must change at logon)' })" 'Gray'

# --- 2. Routes -------------------------------------------------------------

Write-Section '2. Routes SetPassword can take'

foreach ($route in $script:Routes) {
    $reason = if ($route.Port -eq 636) { Test-SecureLdap } else { Test-Port $route.Port }
    $open = -not $reason -or $reason.StartsWith('handshake ok')
    $detail = if ($reason) { $reason } else { 'open' }
    Write-Result "$($Dc):$($route.Port)" "$detail  -  $($route.Needs)" $(if ($open) { 'Green' } else { 'Yellow' })
}

# --- 3. Binds --------------------------------------------------------------

Write-Section '3. Bind modes'

$usable = @()
foreach ($mode in $script:BindModes) {
    $entry = $null
    try {
        $entry = New-Bind $dn $mode
        # A method, not a property read: ETS turns a failed bind's error into a null.
        $entry.RefreshCache()
        Write-Result $mode.Name 'bound and read' 'Green'
        $usable += $mode
    } catch {
        Write-Result $mode.Name (Resolve-Reason $_) 'Yellow'
        Write-Result '' (Get-BindPath $dn $mode) 'DarkGray'
    } finally {
        Close-Bind $entry
    }
}

# --- 4. Rights -------------------------------------------------------------

Write-Section '4. Rights this account holds on the target'

try {
    $aclSearcher = New-Searcher $script:RootPath
    $aclSearcher.Filter = "(distinguishedName=$dn)"
    $aclSearcher.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
    [void]$aclSearcher.PropertiesToLoad.Add('ntsecuritydescriptor')
    $bytes = ($aclSearcher.FindOne()).Properties['ntsecuritydescriptor'][0]

    $sd = New-Object System.DirectoryServices.ActiveDirectorySecurity
    $sd.SetSecurityDescriptorBinaryForm($bytes)
    $mine = @($me.User) + @($me.Groups)
    $ours = @($sd.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
        Where-Object { $_.AccessControlType -eq 'Allow' -and $mine -contains $_.IdentityReference })

    $lockoutGuid = Get-AttributeGuid 'lockoutTime'
    $pwdGuid = Get-AttributeGuid 'pwdLastSet'

    # An ACE covers an attribute when it names it, or names nothing and so covers all.
    function Test-Right([guid]$target, [string]$rights) {
        return @($ours | Where-Object {
                ($_.ObjectType -eq $target -or $_.ObjectType -eq [guid]::Empty) -and
                ($_.ActiveDirectoryRights.ToString() -match $rights)
            }).Count -gt 0
    }

    $checks = @(
        @{ Label = 'reset password'; Guid = $script:ResetPasswordRight; Rights = 'ExtendedRight|GenericAll' }
        @{ Label = 'write lockoutTime'; Guid = $lockoutGuid; Rights = 'WriteProperty|GenericAll|GenericWrite' }
        @{ Label = 'write pwdLastSet'; Guid = $pwdGuid; Rights = 'WriteProperty|GenericAll|GenericWrite' }
    )
    Write-Result 'matching ACEs' "$($ours.Count) for this account and its groups" 'Gray'
    foreach ($check in $checks) {
        if ($null -eq $check.Guid) {
            Write-Result $check.Label 'schema GUID unreadable, so undecided' 'Yellow'
            continue
        }
        $held = Test-Right $check.Guid $check.Rights
        $verdict = if ($held) { 'granted' } else { 'NOT granted' }
        Write-Result $check.Label $verdict $(if ($held) { 'Green' } else { 'Red' })
    }
} catch {
    Write-Result 'rights' "could not read the DACL: $(Resolve-Reason $_)" 'Yellow'
}

# --- 5. Writes -------------------------------------------------------------

if (-not $WriteTest) {
    Write-Host ''
    Write-Host 'Reads only. Sections 2 to 4 are the decision; -WriteTest only confirms it.' `
               -ForegroundColor DarkGray
    return
}

Write-Section "5. Writes (changing $Sam)"

if ($usable.Count -eq 0) {
    Write-Result 'skipped' 'no bind mode succeeded in section 3' 'Red'
    return
}
if ($Sam -ieq $env:USERNAME) {
    Write-Result 'refused' 'that is the account running this, so pass a throwaway one' 'Red'
    return
}
Write-Result 'target' $dn 'Yellow'

# The two plain attribute writes, which are what Unlock-ADAccount and Set-ADUser do.
$entry = New-Bind $dn $usable[0]
try {
    foreach ($pair in @(@{ Name = 'lockoutTime'; Value = 0 }, @{ Name = 'pwdLastSet'; Value = 0 })) {
        try {
            $entry.Properties[$pair.Name].Value = $pair.Value
            $entry.CommitChanges()
            Write-Result $pair.Name "wrote $($pair.Value) via $($usable[0].Name)" 'Green'
        } catch {
            Write-Result $pair.Name (Resolve-Reason $_) 'Red'
        }
    }
} finally {
    Close-Bind $entry
}

# SetPassword is the whole reason this probe exists: each mode reports separately.
foreach ($mode in $usable) {
    $target = $null
    try {
        $target = New-Bind $dn $mode
        $target.Invoke('SetPassword', (New-ProbePassword))
        Write-Result "SetPassword ($($mode.Name))" 'accepted' 'Green'
    } catch {
        Write-Result "SetPassword ($($mode.Name))" "refused: $(Resolve-Reason $_)" 'Red'
    } finally {
        Close-Bind $target
    }
}

# Left cleared rather than forcing a change, since the probe's password is unknown.
$entry = New-Bind $dn $usable[0]
try {
    $entry.Properties['pwdLastSet'].Value = -1
    $entry.CommitChanges()
    Write-Result 'pwdLastSet' 'restored to -1' 'Gray'
} catch {
    Write-Result 'pwdLastSet' "could not restore: $(Resolve-Reason $_)" 'Yellow'
} finally {
    Close-Bind $entry
}
