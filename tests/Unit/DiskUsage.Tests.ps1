using module "..\..\src\Models\DiskUsage.psm1"

Describe "WizTreeCsv.ParseTopFolders" {
    BeforeAll {
        # A representative WizTree folder export: a banner line, the header row,
        # the volume-root total, then folders out of size order. Sizes in bytes.
        $script:Csv = @'
WizTree (4.0.0) (c) 2024 Antibody Software - https://wiztree.com [Generated 2026-06-28]
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\",274877906944,274877906944,2026-06-28,16,500000,40000
"C:\Users\",53687091200,53687091200,2026-06-28,16,200000,15000
"C:\Windows\",32212254720,32212254720,2026-06-28,16,180000,20000
"C:\ProgramData\",10737418240,10737418240,2026-06-28,16,40000,3000
'@
    }

    It "skips the banner + header and parses the folder rows" {
        $r = [WizTreeCsv]::ParseTopFolders($script:Csv, 12)
        $r.Folders.Count | Should -Be 3
    }

    It "excludes the volume-root row" {
        $r = [WizTreeCsv]::ParseTopFolders($script:Csv, 12)
        ($r.Folders.Path) | Should -Not -Contain 'C:\'
    }

    It "ranks folders by size descending" {
        $r = [WizTreeCsv]::ParseTopFolders($script:Csv, 12)
        $r.Folders[0].Path | Should -Be 'C:\Users\'
        $r.Folders[0].SizeBytes | Should -Be 53687091200
        $r.Folders[1].Path | Should -Be 'C:\Windows\'
        $r.Folders[2].Path | Should -Be 'C:\ProgramData\'
    }

    It "caps the result at topN" {
        $r = [WizTreeCsv]::ParseTopFolders($script:Csv, 2)
        $r.Folders.Count | Should -Be 2
        $r.Folders[0].Path | Should -Be 'C:\Users\'
        $r.Folders[1].Path | Should -Be 'C:\Windows\'
    }

    It "stamps ScannedAt with a parseable ISO8601 time" {
        $r = [WizTreeCsv]::ParseTopFolders($script:Csv, 12)
        { [datetime]::Parse($r.ScannedAt) } | Should -Not -Throw
    }

    It "parses a quoted path containing a comma without splitting it" {
        $csv = @'
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\Data, Archived\",2147483648,2147483648,2026-06-28,16,10,2
'@
        $r = [WizTreeCsv]::ParseTopFolders($csv, 12)
        $r.Folders.Count | Should -Be 1
        $r.Folders[0].Path | Should -Be 'C:\Data, Archived\'
        $r.Folders[0].SizeBytes | Should -Be 2147483648
    }

    It "returns an empty report (no throw) for empty or whitespace input" {
        { [WizTreeCsv]::ParseTopFolders('', 12) }    | Should -Not -Throw
        { [WizTreeCsv]::ParseTopFolders($null, 12) } | Should -Not -Throw
        ([WizTreeCsv]::ParseTopFolders('', 12)).Folders.Count | Should -Be 0
    }

    It "returns an empty report when no header row is present" {
        $r = [WizTreeCsv]::ParseTopFolders("just some garbage`nwith no header", 12)
        $r.Folders.Count | Should -Be 0
    }
}

Describe "DiskUsageFormat.SizeLabel" {
    It "formats >= 1 GB as GB" {
        [DiskUsageFormat]::SizeLabel(53687091200) | Should -Be '50 GB'
        [DiskUsageFormat]::SizeLabel(1073741824)  | Should -Be '1 GB'
    }
    It "formats < 1 GB as MB" {
        [DiskUsageFormat]::SizeLabel(524288000) | Should -Be '500 MB'
        [DiskUsageFormat]::SizeLabel(1048576)   | Should -Be '1 MB'
    }
}

Describe "DiskUsageReport round-trip" {
    It "survives ToHashtable -> FromHashtable" {
        $r = [WizTreeCsv]::ParseTopFolders(@'
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\Users\",53687091200,53687091200,2026-06-28,16,200000,15000
"C:\Windows\",32212254720,32212254720,2026-06-28,16,180000,20000
'@, 12)

        $back = [DiskUsageReport]::FromHashtable($r.ToHashtable())
        $back.ScannedAt | Should -Be $r.ScannedAt
        $back.Folders.Count | Should -Be 2
        $back.Folders[0].Path | Should -Be 'C:\Users\'
        $back.Folders[0].SizeBytes | Should -Be 53687091200
        $back.Folders[1].Path | Should -Be 'C:\Windows\'
    }

    It "FromHashtable tolerates null" {
        $r = [DiskUsageReport]::FromHashtable($null)
        $r.Folders.Count | Should -Be 0
    }
}
