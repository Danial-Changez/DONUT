#Requires -Version 5.1
<#
.SYNOPSIS
    Probes whether the three RSAT write operations work over plain System.DirectoryServices.

.DESCRIPTION
    Settles the one open question behind dropping the RSAT ActiveDirectory module:
    Unlock-ADAccount and Set-ADUser map to plain attribute writes, but
    Set-ADAccountPassword maps to IADsUser::SetPassword, which needs a secure
    channel and picks its own route (LDAPS, then Kerberos set-password, then
    NetUserSetInfo). Which of those this site's DCs accept cannot be read out of
    code.

    Run as the account that performs resets today, from a box that reaches the DC.

      1. Target: resolves the account and prints its DN, lock state and pwdLastSet.
      2. Transport: whether 389 and 636 answer on the DC, since LDAPS is the route
         SetPassword prefers.
      3. Binds: binds the DN under each candidate AuthenticationTypes combination
         and reads it back, which separates a bind failure from a write failure.
      4. Rights: whether this caller holds the Reset Password extended right, so a
         failed write in section 5 reads as transport rather than permissions.

    Sections 1-4 are reads and change nothing. Section 5 runs only with -WriteTest.

.PARAMETER Sam
    sAMAccountName to probe. With -WriteTest this account's password IS CHANGED, so
    pass a throwaway account and nothing else.

.PARAMETER Domain
    AD DNS domain to search. Defaults to this session's domain.

.PARAMETER Dc
    Domain controller to bind. Defaults to this session's logon server.

.PARAMETER WriteTest
    Performs the writes: pwdLastSet, lockoutTime, then SetPassword under each bind
    mode that section 3 proved. DESTRUCTIVE - it sets a random password on -Sam and
    does not tell you what it was. The account is left with pwdLastSet cleared.
    Refused when -Sam is the account running the probe.

.EXAMPLE
    pwsh -File tools\Probe-AdWrite.ps1 -Sam testuser01

.EXAMPLE
    pwsh -File tools\Probe-AdWrite.ps1 -Sam testuser01 -WriteTest
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Sam,
    [string] $Domain = $env:USERDNSDOMAIN,
    [string] $Dc = ($env:LOGONSERVER -replace '^\\\\', ''),
    [switch] $WriteTest
)

Add-Type -AssemblyName System.DirectoryServices -ErrorAction SilentlyContinue

# Schema GUID of the Reset Password extended right.
$script:ResetPasswordRight = [guid]'00299570-246d-11d0-a768-00aa006e0529'

$script:BindModes = @(
    @{ Name = 'Secure'; Port = 389; Auth = 'Secure' }
    @{ Name = 'Secure + Sealing + Signing'; Port = 389; Auth = 'Secure, Sealing, Signing' }
    @{ Name = 'Secure + SSL'; Port = 636; Auth = 'Secure, SecureSocketsLayer' }
)

function Write-Section([string]$title) {
    Write-Host ''
    Write-Host $title -ForegroundColor Cyan
}

function Write-Result([string]$label, [string]$value, [string]$colour) {
    Write-Host ("  {0,-30} {1}" -f $label, $value) -ForegroundColor $colour
}

# PowerShell wraps a failed bind's COM error twice before rethrowing it.
function Resolve-Reason($record) {
    $ex = $record.Exception
    while ($ex.InnerException) { $ex = $ex.InnerException }
    return $ex.Message
}

function Close-Bind($entry) {
    if ($null -ne $entry) { try { $entry.Dispose() } catch { } }
}

function New-Bind([string]$dn, [hashtable]$mode) {
    $path = "LDAP://${Dc}:$($mode.Port)/$dn"
    $auth = [System.DirectoryServices.AuthenticationTypes]$mode.Auth
    return New-Object System.DirectoryServices.DirectoryEntry($path, $null, $null, $auth)
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

# --- 1. Target -------------------------------------------------------------

Write-Section '1. Target account'

$root = New-Object System.DirectoryServices.DirectoryEntry("LDAP://$Dc/DC=$($Domain -replace '\.', ',DC=')")
$searcher = New-Object System.DirectoryServices.DirectorySearcher($root)
$searcher.Filter = "(&(objectCategory=person)(objectClass=user)(sAMAccountName=$Sam))"
foreach ($p in @('distinguishedName', 'lockoutTime', 'pwdLastSet', 'userAccountControl')) {
    [void]$searcher.PropertiesToLoad.Add($p)
}

$me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = ([System.Security.Principal.WindowsPrincipal]::new($me)).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Result 'running as' "$($me.Name)$(if ($elevated) { '  (elevated)' })" 'Gray'

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

# --- 2. Transport ----------------------------------------------------------

Write-Section '2. Transport'

foreach ($port in @(389, 636)) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $open = $client.ConnectAsync($Dc, $port).Wait(3000)
        $colour = if ($open) { 'Green' } else { 'Yellow' }
        Write-Result "${Dc}:$port" $(if ($open) { 'open' } else { 'no answer within 3s' }) $colour
    } catch {
        Write-Result "${Dc}:$port" "failed: $($_.Exception.Message)" 'Yellow'
    } finally {
        $client.Dispose()
    }
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
        Write-Result $mode.Name "bound and read (port $($mode.Port))" 'Green'
        $usable += $mode
    } catch {
        Write-Result $mode.Name (Resolve-Reason $_) 'Yellow'
    } finally {
        Close-Bind $entry
    }
}

# --- 4. Rights -------------------------------------------------------------

Write-Section '4. Reset Password right'

try {
    $aclSearcher = New-Object System.DirectoryServices.DirectorySearcher($root)
    $aclSearcher.Filter = "(distinguishedName=$dn)"
    $aclSearcher.SecurityMasks = [System.DirectoryServices.SecurityMasks]::Dacl
    [void]$aclSearcher.PropertiesToLoad.Add('ntsecuritydescriptor')
    $bytes = ($aclSearcher.FindOne()).Properties['ntsecuritydescriptor'][0]

    $sd = New-Object System.DirectoryServices.ActiveDirectorySecurity
    $sd.SetSecurityDescriptorBinaryForm($bytes)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $mine = @($me.User) + @($me.Groups)

    $granted = @($sd.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) |
        Where-Object {
            $_.AccessControlType -eq 'Allow' -and $mine -contains $_.IdentityReference -and
            ($_.ObjectType -eq $script:ResetPasswordRight -or $_.ObjectType -eq [guid]::Empty)
        })

    if ($granted.Count -gt 0) {
        Write-Result 'reset password' "granted by $($granted.Count) ACE(s)" 'Green'
    } else {
        Write-Result 'reset password' 'no matching ACE, so a write failure is permissions' 'Yellow'
    }
} catch {
    Write-Result 'reset password' "could not read the DACL: $($_.Exception.Message)" 'Yellow'
}

# --- 5. Writes -------------------------------------------------------------

if (-not $WriteTest) {
    Write-Host ''
    Write-Host 'Reads only. Re-run with -WriteTest on a throwaway account to test the writes.' `
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
        [void]$target.Invoke('SetPassword', @(New-ProbePassword))
        $target.CommitChanges()
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
