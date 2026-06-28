using module "..\..\src\Models\AdSearchResult.psm1"

Describe "AdFilter.EscapeLdap" {
    It "escapes LDAP filter metacharacters" {
        [AdFilter]::EscapeLdap('a*b(c)d\e') | Should -Be 'a\2ab\28c\29d\5ce'
    }
    It "leaves ordinary text (incl. dots/@) untouched" {
        [AdFilter]::EscapeLdap('sarah.test@cgic.cooperators.ca') | Should -Be 'sarah.test@cgic.cooperators.ca'
    }
    It "returns empty for null/empty input" {
        [AdFilter]::EscapeLdap('')    | Should -Be ''
        [AdFilter]::EscapeLdap($null) | Should -Be ''
    }
}

Describe "AdFilter filter construction" {
    It "UserFilter matches sam/cn/displayName/UPN with the prefix" {
        $f = [AdFilter]::UserFilter('sar')
        foreach ($attr in 'sAMAccountName', 'cn', 'displayName', 'userPrincipalName') {
            $f | Should -Match ([regex]::Escape("$attr=sar*"))
        }
        $f | Should -Match ([regex]::Escape('(objectClass=user)'))
    }
    It "ComputerFilter matches name/sam with the prefix" {
        $f = [AdFilter]::ComputerFilter('WS-01')
        $f | Should -Match ([regex]::Escape('name=WS-01*'))
        $f | Should -Match ([regex]::Escape('(objectCategory=computer)'))
    }
    It "escapes an injection attempt so no extra clause is injected" {
        $f = [AdFilter]::UserFilter('a)(uid=*')
        $f | Should -Match ([regex]::Escape('sAMAccountName=a\29\28uid=\2a'))
        # the raw ')(' break-out must not survive
        $f | Should -Not -Match ([regex]::Escape(')(uid='))
    }
}

Describe "AdFilter account-control decode" {
    It "IsLockedFromComputed is true only when UF_LOCKOUT (0x10) is set" {
        [AdFilter]::IsLockedFromComputed(0x10)  | Should -BeTrue
        [AdFilter]::IsLockedFromComputed(16)    | Should -BeTrue
        [AdFilter]::IsLockedFromComputed('16')  | Should -BeTrue   # string coerces
        [AdFilter]::IsLockedFromComputed(0x210) | Should -BeTrue   # other bits + lockout
    }
    It "IsLockedFromComputed is false when the bit is clear / null" {
        [AdFilter]::IsLockedFromComputed(0)     | Should -BeFalse
        [AdFilter]::IsLockedFromComputed(0x200) | Should -BeFalse  # NORMAL_ACCOUNT, no lockout
        [AdFilter]::IsLockedFromComputed($null) | Should -BeFalse
    }
    It "IsDisabledFromUac is true only when UF_ACCOUNTDISABLE (0x2) is set" {
        [AdFilter]::IsDisabledFromUac(0x2)   | Should -BeTrue
        [AdFilter]::IsDisabledFromUac(0x202) | Should -BeTrue
        [AdFilter]::IsDisabledFromUac(0x200) | Should -BeFalse
    }
}

Describe "AdSearchResult" {
    It "Label() returns the UPN for users, falling back to sam" {
        $u = [AdSearchResult]::new()
        $u.Kind = 'User'; $u.UserPrincipalName = 'sarah.test@cgic.cooperators.ca'; $u.SamAccountName = 'sarah'
        $u.Label() | Should -Be 'sarah.test@cgic.cooperators.ca'
        $u.UserPrincipalName = ''
        $u.Label() | Should -Be 'sarah'
    }
    It "Label() returns the name for computers" {
        $c = [AdSearchResult]::new(); $c.Kind = 'Computer'; $c.Name = 'WS-014'
        $c.Label() | Should -Be 'WS-014'
    }
    It "Key() distinguishes kind+domain+sam case-insensitively" {
        $a = [AdSearchResult]::new(); $a.Kind = 'User'; $a.Domain = 'D'; $a.SamAccountName = 'Sam'
        $b = [AdSearchResult]::new(); $b.Kind = 'User'; $b.Domain = 'd'; $b.SamAccountName = 'sam'
        $a.Key() | Should -Be $b.Key()
        $c = [AdSearchResult]::new(); $c.Kind = 'Computer'; $c.Domain = 'd'; $c.SamAccountName = 'sam'
        $c.Key() | Should -Not -Be $a.Key()
    }
}
