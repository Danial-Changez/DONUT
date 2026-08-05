using module "..\..\src\Models\AdSearchResult.psm1"

Describe "AdFilter.EscapeLdap" {
    It "escapes LDAP filter metacharacters" {
        [AdFilter]::EscapeLdap('a*b(c)d\e') | Should -Be 'a\2ab\28c\29d\5ce'
    }
    It "leaves ordinary text (incl. dots/@) untouched" {
        [AdFilter]::EscapeLdap('sarah.test@contoso.com') | Should -Be 'sarah.test@contoso.com'
    }
    It "returns empty for null/empty input" {
        [AdFilter]::EscapeLdap('')    | Should -Be ''
        [AdFilter]::EscapeLdap($null) | Should -Be ''
    }
}

Describe "AdFilter filter construction" {
    It "UserFilter matches sam/cn/displayName/UPN/sn with the prefix" {
        $f = [AdFilter]::UserFilter('sar')
        foreach ($attr in 'sAMAccountName', 'cn', 'displayName', 'userPrincipalName', 'sn') {
            $f | Should -Match ([regex]::Escape("$attr=sar*"))
        }
        $f | Should -Match ([regex]::Escape('(objectClass=user)'))
    }

    # ANR would also match office and proxy attributes, crowding real people out of the cap.
    It "reaches a surname without pulling in ANR's office and proxy attributes" {
        $f = [AdFilter]::UserFilter('sar')
        $f | Should -Match ([regex]::Escape('sn=sar*'))
        $f | Should -Not -Match 'anr='
        $f | Should -Not -Match 'physicalDeliveryOfficeName|proxyAddresses'
    }
    It "ComputerFilter matches name/sam with the prefix" {
        $f = [AdFilter]::ComputerFilter('WS-01')
        $f | Should -Match ([regex]::Escape('name=WS-01*'))
        $f | Should -Match ([regex]::Escape('(objectCategory=computer)'))
    }
    It "CombinedFilter ORs the computer and user filters into one query" {
        $f = [AdFilter]::CombinedFilter('sar')
        $f | Should -Match ([regex]::Escape('(objectCategory=computer)'))
        $f | Should -Match ([regex]::Escape('(objectClass=user)'))
        $f | Should -Match '^\(\|\('   # Top-level OR.
    }
    It "escapes an injection attempt so no extra clause is injected" {
        $f = [AdFilter]::UserFilter('a)(uid=*')
        $f | Should -Match ([regex]::Escape('sAMAccountName=a\29\28uid=\2a'))
        $f | Should -Not -Match ([regex]::Escape(')(uid='))
    }
}

Describe "AdSearchRank" {
    BeforeAll {
        function New-Row([string]$display, [string]$name, [string]$sam, [string]$upn) {
            return [pscustomobject]@{
                DisplayName = $display; Name = $name
                SamAccountName = $sam; UserPrincipalName = $upn
            }
        }
    }

    It "ranks a displayName match ahead of cn, sam and UPN" {
        $display = New-Row 'Dan Okafor' 'Okafor' 'dokafor' 'dokafor@x'
        $cn = New-Row 'Kim Roy' 'Dan Roy' 'kroy' 'kroy@x'
        $sam = New-Row 'Kim Roy' 'Roy' 'danroy' 'kroy@x'
        $upn = New-Row 'Kim Roy' 'Roy' 'kroy' 'danroy@x'

        [AdSearchRank]::Of($display, 'dan') | Should -Be 0
        [AdSearchRank]::Of($cn, 'dan') | Should -Be 1
        [AdSearchRank]::Of($sam, 'dan') | Should -Be 2
        [AdSearchRank]::Of($upn, 'dan') | Should -Be 3
    }

    # The whole point of the tier: sn is why the row came back, but people type first names.
    It "puts a surname-only match last, since nothing visible explains it" {
        $surname = New-Row 'Kim Danielson' 'Kim Danielson' 'kdanielson' 'kdanielson@x'
        [AdSearchRank]::Of($surname, 'dan') | Should -Be 4
    }

    # A cn of "Last, First" is a field the finder shows, so it must not drop to the sn tier.
    It "treats a 'Last, First' cn as the visible match it is" {
        $lastFirst = New-Row 'Kim Danielson' 'Danielson, Kim' 'kdanielson' 'kdanielson@x'
        [AdSearchRank]::Of($lastFirst, 'dan') | Should -Be 1
    }

    It "orders a mixed set strongest-match first" {
        $rows = @(
            (New-Row 'Kim Danielson' 'X' 'kd' 'kd@x'),      # Surname only, ranks last.
            (New-Row 'Dan Okafor' 'Okafor' 'dok' 'dok@x'),  # DisplayName, ranks first.
            (New-Row 'Kim Roy' 'Roy' 'danroy' 'kr@x')       # Sam, ranks middle.
        )
        $ordered = [AdSearchRank]::Order($rows, 'dan')
        @($ordered).Count | Should -Be 3
        $ordered[0].DisplayName | Should -BeExactly 'Dan Okafor'
        $ordered[1].SamAccountName | Should -BeExactly 'danroy'
        $ordered[2].DisplayName | Should -BeExactly 'Kim Danielson'
    }

    # A redraw must not reshuffle rows under the cursor while the user is arrowing down.
    It "breaks ties deterministically so a re-render keeps the same order" {
        $rows = @(
            (New-Row 'Dan Zephyr' 'Z' 'dz' 'dz@x'),
            (New-Row 'Dan Abbott' 'A' 'da' 'da@x'),
            (New-Row 'Dan Mbeki' 'M' 'dm' 'dm@x')
        )
        $first = @([AdSearchRank]::Order($rows, 'dan') | ForEach-Object { $_.DisplayName })
        $again = @([AdSearchRank]::Order(($rows[2], $rows[0], $rows[1]), 'dan') |
                ForEach-Object { $_.DisplayName })
        $first -join ',' | Should -BeExactly 'Dan Abbott,Dan Mbeki,Dan Zephyr'
        $again -join ',' | Should -BeExactly ($first -join ',')
    }

    It "is safe on a null row and an empty prefix" {
        [AdSearchRank]::Of($null, 'dan') | Should -Be 99
        [AdSearchRank]::Of((New-Row 'Dan' 'Dan' 'dan' 'dan@x'), '  ') | Should -Be 99
        @([AdSearchRank]::Order(@(), 'dan')).Count | Should -Be 0
    }

    It "ignores case, so a typed prefix matches however the directory stored it" {
        [AdSearchRank]::Of((New-Row 'DANIEL ROY' 'x' 'y' 'z'), 'dan') | Should -Be 0
        [AdSearchRank]::Of((New-Row 'daniel roy' 'x' 'y' 'z'), 'DAN') | Should -Be 0
    }
}

Describe "AdFilter escaping" {
    It "escapes an injection attempt so no extra clause is injected" {
        $f = [AdFilter]::UserFilter('a)(uid=*')
        $f | Should -Match ([regex]::Escape('sAMAccountName=a\29\28uid=\2a'))
        $f | Should -Not -Match ([regex]::Escape(')(uid='))
    }
}

Describe "AdFilter account-control decode" {
    It "IsLockedFromComputed is true only when UF_LOCKOUT (0x10) is set" {
        [AdFilter]::IsLockedFromComputed(0x10)  | Should -BeTrue
        [AdFilter]::IsLockedFromComputed(16)    | Should -BeTrue
        [AdFilter]::IsLockedFromComputed('16')  | Should -BeTrue   # String coerces.
        [AdFilter]::IsLockedFromComputed(0x210) | Should -BeTrue   # Other bits plus lockout.
    }
    It "IsLockedFromComputed is false when the bit is clear / null" {
        [AdFilter]::IsLockedFromComputed(0)     | Should -BeFalse
        [AdFilter]::IsLockedFromComputed(0x200) | Should -BeFalse  # NORMAL_ACCOUNT, no lockout.
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
        $u.Kind = 'User'; $u.UserPrincipalName = 'sarah.test@contoso.com'; $u.SamAccountName = 'sarah'
        $u.Label() | Should -Be 'sarah.test@contoso.com'
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
