using module "..\..\src\Models\DcuUpdate.psm1"

Describe "DcuUpdate" {
    Context "New() factory" {
        It "formats a matched update as 'current -> new' and carries the flags" {
            $u = [DcuUpdate]::Create('Realtek Audio', '6.0.995', '6.0.900', $true, $true,
                'Recommended', 'Audio', 264884984)
            $u.Name | Should -Be 'Realtek Audio'
            $u.IsNewer | Should -BeTrue
            $u.VersionText | Should -Be '6.0.900  →  6.0.995'
            $u.Category | Should -Be 'Audio'
            $u.Urgency | Should -Be 'Recommended'
        }

        It "formats an unmatched update as the target version alone (no '(latest)')" {
            $u = [DcuUpdate]::Create('Dell BIOS', '1.36.0', '', $false, $false,
                'Urgent', 'BIOS', 28033352)
            $u.VersionText | Should -Be '1.36.0'
        }

        It "renders human-readable sizes and blanks a zero size" {
            ([DcuUpdate]::Create('x', '1', '', $false, $false, '', '', 264884984)).SizeText |
                Should -Be '252.6 MB'
            ([DcuUpdate]::Create('x', '1', '', $false, $false, '', '', 28033352)).SizeText |
                Should -Be '26.7 MB'
            ([DcuUpdate]::Create('x', '1', '', $false, $false, '', '', 2147483648)).SizeText |
                Should -Be '2 GB'
            ([DcuUpdate]::Create('x', '1', '', $false, $false, '', '', 0)).SizeText |
                Should -Be ''
        }
    }

    Context "UrgencyRank - severity ordering" {
        It "ranks Urgent < Recommended < Optional < unknown (case-insensitive)" {
            [DcuUpdate]::UrgencyRank('Urgent') | Should -Be 0
            [DcuUpdate]::UrgencyRank('recommended') | Should -Be 1
            [DcuUpdate]::UrgencyRank('Optional') | Should -Be 2
            [DcuUpdate]::UrgencyRank('') | Should -Be 3
            [DcuUpdate]::UrgencyRank('anything-else') | Should -Be 3
        }
        It "sorts a mixed list most-urgent first" {
            $ranks = @('Optional', 'Urgent', 'Recommended') |
                ForEach-Object { [DcuUpdate]::UrgencyRank($_) } | Sort-Object
            $ranks | Should -Be @(0, 1, 2)
        }
    }

    Context "child-element XML parse pattern" {
        It "reads each field via SelectSingleNode (InnerText mashes the children)" {
            $xml = [xml]@"
<updates><update>
  <release>Y8R01</release><name>Dell Latitude 5330 System BIOS</name><version>1.36.0</version>
  <urgency>Urgent</urgency><type>BIOS</type><category>BIOS</category><bytes>28033352</bytes>
</update></updates>
"@
            $node = $xml.SelectNodes("//update")[0]
            $node.SelectSingleNode('name').InnerText | Should -Be 'Dell Latitude 5330 System BIOS'
            $node.SelectSingleNode('version').InnerText | Should -Be '1.36.0'
            $node.SelectSingleNode('urgency').InnerText | Should -Be 'Urgent'
            $node.SelectSingleNode('bytes').InnerText | Should -Be '28033352'
            # Why we don't use InnerText: it concatenates every child into one string.
            $node.InnerText | Should -Match 'Y8R01Dell Latitude 5330 System BIOS1.36.0'
        }
    }
}
