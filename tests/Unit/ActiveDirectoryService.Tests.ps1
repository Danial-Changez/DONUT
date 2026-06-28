using module "..\..\src\Models\AdSearchResult.psm1"
using module "..\..\src\Services\ActiveDirectoryService.psm1"
using module "..\..\src\Core\LogService.psm1"
using module "..\Helpers\CapturingLogService.psm1"

# Fakes the env-coupled AD seams so the multi-domain aggregation / mapping /
# guard logic runs entirely off a domain.
#   UserRows/ComputerRows: domain -> hashtable[] of rows the directory "returns"
#   FailDomains:           domains whose query throws (down/untrusted forest)
#   Unlocks:               records each InvokeUnlock call
class FakeAdService : ActiveDirectoryService {
    [hashtable] $UserRows = @{}
    [hashtable] $ComputerRows = @{}
    [string[]]  $FailDomains = @()
    [int]       $QueryCount = 0
    [System.Collections.Generic.List[hashtable]] $Unlocks
    [bool]      $UnlockThrows = $false

    FakeAdService([string[]]$domains, [LogService]$logger) : base($domains, $logger) {
        $this.Unlocks = [System.Collections.Generic.List[hashtable]]::new()
    }

    hidden [hashtable[]] QueryDirectory([string]$domain, [string]$filter, [string[]]$props, [int]$max) {
        $this.QueryCount++
        if ($this.FailDomains -contains $domain) { throw "domain $domain unreachable" }
        $rows = if ($filter -like '*objectCategory=computer*') { $this.ComputerRows[$domain] } else { $this.UserRows[$domain] }
        if ($null -eq $rows) { return @() }
        return @($rows)
    }

    hidden [void] InvokeUnlock([string]$sam, [string]$domain) {
        $this.Unlocks.Add(@{ sam = $sam; domain = $domain })
        if ($this.UnlockThrows) { throw "access is denied" }
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
        }
    }
    function New-CompRow([string]$name) {
        return @{ 'name' = $name; 'sAMAccountName' = "$name`$"; 'userAccountControl' = 0x1000; 'distinguishedName' = "CN=$name,DC=x" }
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
        $svc.UserRows['d1'] = @(New-UserRow 'sarah' 'sarah.test@cgic.cooperators.ca' 'Sarah Test' $true)
        $svc.UserRows['d2'] = @(New-UserRow 'sam2'  'sam2@clic'                      'Sam Two'    $false)
        $svc.ComputerRows['d1'] = @(New-CompRow 'WS-014')

        $r = @($svc.Search('sar'))
        $r.Count | Should -Be 3

        $sarah = $r | Where-Object { $_.SamAccountName -eq 'sarah' }
        $sarah.Kind | Should -Be 'User'
        $sarah.Domain | Should -Be 'd1'
        $sarah.UserPrincipalName | Should -Be 'sarah.test@cgic.cooperators.ca'
        $sarah.LockedOut | Should -BeTrue

        ($r | Where-Object { $_.SamAccountName -eq 'sam2' }).LockedOut | Should -BeFalse

        $comp = $r | Where-Object { $_.Kind -eq 'Computer' }
        $comp.Name | Should -Be 'WS-014'
        $comp.SamAccountName | Should -Be 'WS-014'   # trailing '$' stripped
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

    It "dedupes identical rows returned within a forest" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.UserRows['d1'] = @((New-UserRow 'dup' 'dup@x' 'Dup' $true), (New-UserRow 'dup' 'dup@x' 'Dup' $true))
        @($svc.Search('dup')).Count | Should -Be 1
    }
}

Describe "ActiveDirectoryService.UnlockUser" {
    It "unlocks a user against its home domain and logs INFO" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $u = [AdSearchResult]::new(); $u.Kind = 'User'; $u.SamAccountName = 'sarah'; $u.Domain = 'prod.cgic.ca'

        $svc.UnlockUser($u) | Should -BeTrue
        $svc.Unlocks.Count | Should -Be 1
        $svc.Unlocks[0].sam | Should -Be 'sarah'
        $svc.Unlocks[0].domain | Should -Be 'prod.cgic.ca'
        $log.HasLevel('INFO') | Should -BeTrue
    }

    It "returns false and logs ERROR when the unlock throws (e.g. access denied)" {
        $log = [CapturingLogService]::new()
        $svc = [FakeAdService]::new(@('d1'), $log)
        $svc.UnlockThrows = $true
        $u = [AdSearchResult]::new(); $u.Kind = 'User'; $u.SamAccountName = 'sarah'; $u.Domain = 'd1'

        $svc.UnlockUser($u) | Should -BeFalse
        $log.HasLevel('ERROR') | Should -BeTrue
    }

    It "guards: null, non-user, and blank-sam inputs return false without calling the seam" {
        $svc = [FakeAdService]::new(@('d1'), $null)
        $svc.UnlockUser($null) | Should -BeFalse
        $comp = [AdSearchResult]::new(); $comp.Kind = 'Computer'; $comp.SamAccountName = 'WS-014'
        $svc.UnlockUser($comp) | Should -BeFalse
        $blank = [AdSearchResult]::new(); $blank.Kind = 'User'; $blank.SamAccountName = ''
        $svc.UnlockUser($blank) | Should -BeFalse
        $svc.Unlocks.Count | Should -Be 0
    }
}
