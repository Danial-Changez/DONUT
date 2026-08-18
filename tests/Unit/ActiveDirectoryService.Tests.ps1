using module "..\..\src\Models\AdSearchResult.psm1"
using module "..\..\src\Models\TempPassword.psm1"
using module "..\..\src\Services\ActiveDirectoryService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Fakes the env-coupled AD seams so aggregation, mapping, and guards run entirely off a domain:
# - UserRows and ComputerRows: rows the directory returns, keyed by domain.
# - FailDomains: domains whose query throws, for a down or untrusted forest.
# - Unlocks and Resets: record each InvokeUnlock and InvokeReset call.
class FakeAdService : ActiveDirectoryService {
    [hashtable] $UserRows = @{}
    [hashtable] $ComputerRows = @{}
    [string[]]  $FailDomains = @()
    [int]       $QueryCount = 0
    [System.Collections.Generic.List[hashtable]] $Unlocks
    [bool]      $UnlockThrows = $false
    [System.Collections.Generic.List[hashtable]] $Resets
    [bool]      $ResetThrows = $false

    FakeAdService([string[]]$domains, [LogService]$logger) : base($domains, $logger) {
        $this.Unlocks = [System.Collections.Generic.List[hashtable]]::new()
        $this.Resets = [System.Collections.Generic.List[hashtable]]::new()
    }

    hidden [hashtable[]] QueryDirectory([string]$domain, [string]$filter, [string[]]$props, [int]$max) {
        $this.QueryCount++
        if ($this.FailDomains -contains $domain) { throw "domain $domain unreachable" }
        # The combined filter asks for computers and users at once, so return both kinds.
        $rows = @()
        if ($null -ne $this.ComputerRows[$domain]) { $rows += $this.ComputerRows[$domain] }
        if ($null -ne $this.UserRows[$domain]) { $rows += $this.UserRows[$domain] }
        return @($rows)
    }

    hidden [void] InvokeUnlock([string]$dn) {
        $this.Unlocks.Add(@{ dn = $dn })
        if ($this.UnlockThrows) { throw "access is denied" }
    }

    # Records HasPassword only, the fake must never hold the plaintext either.
    hidden [void] InvokeReset([string]$dn, [securestring]$newPassword, [bool]$changeAtLogon) {
        $this.Resets.Add(@{
                dn = $dn; changeAtLogon = $changeAtLogon
                HasPassword = ($null -ne $newPassword -and $newPassword.Length -gt 0)
            })
        if ($this.ResetThrows) { throw "access is denied" }
    }
}

BeforeAll {
    function New-UserRow([string]$sam, [string]$upn, [string]$display, [bool]$locked) {
        return @{
            'sAMAccountName'                     = $sam
            'userPrincipalName'                  = $upn
            'displayName'                        = $display
            'name'                               = $display
            'msDS-User-Account-Control-Computed' = $(if ($locked) { 0x10 } else { 0x0 })
            'userAccountControl'                 = 0x200
            'distinguishedName'                  = "CN=$sam,DC=x"
            'objectCategory'                     = 'CN=Person,CN=Schema,CN=Configuration,DC=x'
        }
    }
    # Carries a DN, since unlock and reset both bind it now.
    function New-User([string]$sam, [string]$domain) {
        $u = [AdSearchResult]::new()
        $u.Kind = 'User'; $u.SamAccountName = $sam; $u.Domain = $domain
        $u.DistinguishedName = "CN=$sam,DC=$($domain -replace '\.', ',DC=')"
        return $u
    }
    function New-CompRow([string]$name) {
        return @{
            'name'               = $name
            'sAMAccountName'     = "$name`$"
            'userAccountControl' = 0x1000
            'distinguishedName'  = "CN=$name,DC=x"
            'objectCategory'     = 'CN=Computer,CN=Schema,CN=Configuration,DC=x'
        }
    }
}

Describe "ActiveDirectoryService.Search" {
    It "returns empty and never queries when the prefix is shorter than MinPrefix" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.UserRows['d1'] = @(New-UserRow 'sarah' 's@x' 'Sarah' $true)
        @($svc.Search('sa')).Count | Should -Be 0
        $svc.QueryCount | Should -Be 0
    }

    It "aggregates computers + users across all forests and maps fields" {
        $svc = [FakeAdService]::new(@('d1', 'd2'), $null)
        $svc.UserRows['d1'] = @(New-UserRow 'sarah' 'sarah.test@contoso.com' 'Sarah Test' $true)
        $svc.UserRows['d2'] = @(New-UserRow 'sam2'  'sam2@fabrikam'                      'Sam Two'    $false)
        $svc.ComputerRows['d1'] = @(New-CompRow 'WS-014')

        $r = @($svc.Search('sar'))
        $r.Count | Should -Be 3

        $sarah = $r | Where-Object { $_.SamAccountName -eq 'sarah' }
        $sarah.Kind | Should -Be 'User'
        $sarah.Domain | Should -Be 'd1'
        $sarah.UserPrincipalName | Should -Be 'sarah.test@contoso.com'
        $sarah.LockedOut | Should -BeTrue

        ($r | Where-Object { $_.SamAccountName -eq 'sam2' }).LockedOut | Should -BeFalse

        $comp = $r | Where-Object { $_.Kind -eq 'Computer' }
        $comp.Name | Should -Be 'WS-014'
        $comp.SamAccountName | Should -Be 'WS-014'   # Trailing '$' stripped.
    }

    It "isolates a failed forest: others still return and a WARN is logged" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1', 'd2'), $log)
        $svc.FailDomains = @('d1')
        $svc.UserRows['d2'] = @(New-UserRow 'bob' 'bob@x' 'Bob' $false)

        $r = @($svc.Search('bob'))
        $r.Count | Should -Be 1
        $r[0].SamAccountName | Should -Be 'bob'
        $log.HasLevel('WARN') | Should -BeTrue
    }

    It "records the failed forest even with no logger, naming it and the reason" {
        # The worker passes a null logger, so only LastErrors tells unreachable from empty.
        $svc = [FakeAdService]::new(@('d1', 'd2'), $null)
        $svc.FailDomains = @('d1')
        $svc.UserRows['d2'] = @(New-UserRow 'bob' 'bob@x' 'Bob' $false)

        $r = @($svc.Search('bob'))

        $r.Count | Should -Be 1
        @($svc.LastErrors).Count | Should -Be 1
        $svc.LastErrors[0] | Should -BeLike 'd1:*unreachable*'
    }

    It "clears the previous search's failures so a recovered forest stops reporting" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.FailDomains = @('d1')
        [void]$svc.Search('bob')
        @($svc.LastErrors).Count | Should -Be 1

        $svc.FailDomains = @()
        $svc.UserRows['d1'] = @(New-UserRow 'bob' 'bob@x' 'Bob' $false)
        [void]$svc.Search('bob')

        @($svc.LastErrors).Count | Should -Be 0
    }

    It "dedupes identical rows returned within a forest" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.UserRows['d1'] = @((New-UserRow 'dup' 'dup@x' 'Dup' $true), (New-UserRow 'dup' 'dup@x' 'Dup' $true))
        @($svc.Search('dup')).Count | Should -Be 1
    }
}

Describe "ActiveDirectoryService.BindPath" {
    It "binds the DN serverless, so the locator routes it to the DN's own domain" {
        [ActiveDirectoryService]::BindPath('CN=sarah,OU=Staff,DC=child,DC=corp,DC=com') |
            Should -BeExactly 'LDAP://CN=sarah,OU=Staff,DC=child,DC=corp,DC=com'
    }

    # Naming a server is what pinned the row's forest and broke child/sibling domains.
    It "never names a server" {
        foreach ($dn in @('CN=x,DC=sib,DC=com', 'CN=y,OU=z,DC=a,DC=b,DC=c')) {
            [ActiveDirectoryService]::BindPath($dn) | Should -Not -Match '^LDAP://[^/]+/'
        }
    }
}

Describe "ActiveDirectoryService.UnlockUser" {
    It "unlocks a user against its home domain and logs INFO" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $u = New-User 'sarah' 'prod.contoso.com'

        $svc.UnlockUser($u) | Should -BeTrue
        $svc.Unlocks.Count | Should -Be 1
        $svc.Unlocks[0].dn | Should -Be 'CN=sarah,DC=prod,DC=contoso,DC=com'
        $log.HasLevel('INFO') | Should -BeTrue
    }

    It "returns false and logs ERROR when the unlock throws (e.g. access denied)" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $svc.UnlockThrows = $true

        $svc.UnlockUser((New-User 'sarah' 'd1')) | Should -BeFalse
        $log.HasLevel('ERROR') | Should -BeTrue
    }

    It "guards: null, non-user, and blank-sam inputs return false without calling the seam" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.UnlockUser($null) | Should -BeFalse
        $comp = [AdSearchResult]::new(); $comp.Kind = 'Computer'; $comp.SamAccountName = 'WS-014'
        $svc.UnlockUser($comp) | Should -BeFalse
        $blank = [AdSearchResult]::new(); $blank.Kind = 'User'; $blank.SamAccountName = ''
        $svc.UnlockUser($blank) | Should -BeFalse
        $noDn = [AdSearchResult]::new(); $noDn.Kind = 'User'; $noDn.SamAccountName = 'sarah'
        $svc.UnlockUser($noDn) | Should -BeFalse
        $svc.Unlocks.Count | Should -Be 0
    }
}

Describe "ActiveDirectoryService.ResetPassword" {
    It "resets against the home domain, records the flag, and logs INFO" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $secure = [TempPassword]::ToSecure('Abcde-Fghjk-23')

        $svc.ResetPassword((New-User 'sarah' 'prod.contoso.com'), $secure, $true) | Should -BeTrue
        $svc.Resets.Count | Should -Be 1
        $svc.Resets[0].dn | Should -Be 'CN=sarah,DC=prod,DC=contoso,DC=com'
        $svc.Resets[0].changeAtLogon | Should -BeTrue
        $svc.Resets[0].HasPassword | Should -BeTrue
        $log.HasLevel('INFO') | Should -BeTrue
    }

    It "passes changeAtLogon=false through untouched" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $secure = [TempPassword]::ToSecure('Abcde-Fghjk-23')
        $svc.ResetPassword((New-User 'bob' 'd1'), $secure, $false) | Should -BeTrue
        $svc.Resets[0].changeAtLogon | Should -BeFalse
    }

    It "never logs the password, on success or failure" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $plain = 'Abcde-Fghjk-23'
        [void]$svc.ResetPassword((New-User 'sarah' 'd1'), [TempPassword]::ToSecure($plain), $true)
        $svc.ResetThrows = $true
        [void]$svc.ResetPassword((New-User 'sarah' 'd1'), [TempPassword]::ToSecure($plain), $true)
        $log.Contains($plain) | Should -BeFalse
    }

    It "returns false and logs ERROR when the reset throws (e.g. access denied)" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $svc.ResetThrows = $true
        $secure = [TempPassword]::ToSecure('Abcde-Fghjk-23')

        $svc.ResetPassword((New-User 'sarah' 'd1'), $secure, $true) | Should -BeFalse
        $log.HasLevel('ERROR') | Should -BeTrue
    }

    It "guards: null user, non-user, blank sam, and empty password skip the seam" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $secure = [TempPassword]::ToSecure('Abcde-Fghjk-23')

        $svc.ResetPassword($null, $secure, $true) | Should -BeFalse
        $comp = [AdSearchResult]::new(); $comp.Kind = 'Computer'; $comp.SamAccountName = 'WS-014'
        $svc.ResetPassword($comp, $secure, $true) | Should -BeFalse
        $blank = [AdSearchResult]::new(); $blank.Kind = 'User'; $blank.SamAccountName = ''
        $svc.ResetPassword($blank, $secure, $true) | Should -BeFalse
        $noDn = [AdSearchResult]::new(); $noDn.Kind = 'User'; $noDn.SamAccountName = 'sarah'
        $svc.ResetPassword($noDn, $secure, $true) | Should -BeFalse
        $svc.ResetPassword((New-User 'sarah' 'd1'), [TempPassword]::ToSecure(''), $true) |
            Should -BeFalse
        $svc.ResetPassword((New-User 'sarah' 'd1'), $null, $true) | Should -BeFalse
        $svc.Resets.Count | Should -Be 0
    }
}
