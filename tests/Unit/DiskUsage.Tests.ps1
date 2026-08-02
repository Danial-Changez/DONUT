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

    It "tolerates a Size column that is not immediately after File Name" {
        $csv = @'
"Files","File Name","Size"
10,"C:\Users\",53687091200
'@
        $r = [WizTreeCsv]::ParseTopFolders($csv, 12)
        $r.Folders.Count | Should -Be 1
        $r.Folders[0].SizeBytes | Should -Be 53687091200
    }
}

Describe "WizTreeCsv.ParseTopFoldersFromFile" {
    It "streams the same result as the in-memory parse" {
        $csv = @'
WizTree (4.0.0) banner line
"File Name","Size","Allocated","Modified","Attributes","Files","Folders"
"C:\",274877906944,274877906944,2026-06-28,16,500000,40000
"C:\Users\",53687091200,53687091200,2026-06-28,16,200000,15000
"C:\Data, Archived\",2147483648,2147483648,2026-06-28,16,10,2
'@
        $path = Join-Path $TestDrive 'wiztree.csv'
        Set-Content -Path $path -Value $csv -Encoding UTF8

        $r = [WizTreeCsv]::ParseTopFoldersFromFile($path, 12)
        $r.Folders.Count | Should -Be 2
        $r.Folders[0].Path | Should -Be 'C:\Users\'
        $r.Folders[1].Path | Should -Be 'C:\Data, Archived\'
        $r.Folders[1].SizeBytes | Should -Be 2147483648
    }

    It "returns an empty report (no throw) for a missing file" {
        $missing = Join-Path $TestDrive 'not-there.csv'
        { [WizTreeCsv]::ParseTopFoldersFromFile($missing, 12) } | Should -Not -Throw
        ([WizTreeCsv]::ParseTopFoldersFromFile($missing, 12)).Folders.Count | Should -Be 0
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
    It "formats < 1 MB as KB, never a 0 MB row" {
        [DiskUsageFormat]::SizeLabel(524288) | Should -Be '512 KB'
        [DiskUsageFormat]::SizeLabel(1024)   | Should -Be '1 KB'
        [DiskUsageFormat]::SizeLabel(0)      | Should -Be '0 KB'
    }
}

Describe "DiskUsageTree.BuildNested" {
    BeforeAll {
        function New-Folder([string]$path, [long]$size) {
            $f = [FolderUsage]::new(); $f.Path = $path; $f.SizeBytes = $size; $f
        }
    }

    It "returns roots with children nested by path containment (size order preserved)" {
        $folders = @(
            (New-Folder 'C:\Users\' 180),
            (New-Folder 'C:\Windows\' 100),
            (New-Folder 'C:\Users\CE\' 40),
            (New-Folder 'C:\Users\CE\OneDrive\' 36),
            (New-Folder 'C:\Windows\Installer\' 30)
        )
        $roots = [DiskUsageTree]::BuildNested($folders)

        ($roots | ForEach-Object { $_.Path }) | Should -Be @('C:\Users\', 'C:\Windows\')
        $users = $roots[0]
        $users.Depth | Should -Be 0
        ($users.Children | ForEach-Object { $_.Label }) | Should -Be @('CE\')
        $ce = $users.Children[0]
        $ce.Depth | Should -Be 1
        ($ce.Children | ForEach-Object { $_.Label }) | Should -Be @('OneDrive\')
        $ce.Children[0].Depth | Should -Be 2
        ($roots[1].Children | ForEach-Object { $_.Label }) | Should -Be @('Installer\')
    }

    It "treats a folder with no listed ancestor as a root showing its full path" {
        $roots = [DiskUsageTree]::BuildNested(@(
                (New-Folder 'C:\Windows\' 100),
                (New-Folder 'C:\Users\CE\Deep\' 50)   # parent C:\Users\ not in the list
            ))
        $deep = $roots | Where-Object { $_.Path -eq 'C:\Users\CE\Deep\' }
        $deep.Depth | Should -Be 0
        $deep.Label | Should -Be 'C:\Users\CE\Deep\'
    }

    It "matches ancestors case-insensitively" {
        $roots = [DiskUsageTree]::BuildNested(@(
                (New-Folder 'C:\Users\' 180),
                (New-Folder 'c:\users\CE\' 40)
            ))
        $roots.Count | Should -Be 1
        $roots[0].Children[0].Depth | Should -Be 1
    }

    It "does not nest a sibling that merely shares a name prefix" {
        $roots = [DiskUsageTree]::BuildNested(@(
                (New-Folder 'C:\Users\' 180),
                (New-Folder 'C:\UsersData\' 40)   # not a child of C:\Users\
            ))
        ($roots | ForEach-Object { $_.Depth }) | Should -Be @(0, 0)
    }

    It "returns empty for an empty list" {
        ([DiskUsageTree]::BuildNested(@())).Count | Should -Be 0
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
