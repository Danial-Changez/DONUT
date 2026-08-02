using module "..\..\src\Models\DiskUsage.psm1"
using module "..\..\src\UI\ViewModels\FolderNodeViewModel.psm1"

Describe "FolderNodeViewModel" {
    BeforeAll {
        function New-Report([hashtable[]]$folders) {
            $r = [DiskUsageReport]::new()
            $r.Folders = @($folders | ForEach-Object {
                $f = [FolderUsage]::new()
                $f.Path = $_.Path
                $f.SizeBytes = [long]$_.Size
                $f
            })
            return $r
        }
    }

    It "maps a nested report to display nodes (label, size, depth, root flag, children)" {
        $report = New-Report @(
            @{ Path = 'C:\Users';            Size = 50GB },
            @{ Path = 'C:\Users\bob\Videos'; Size = 20GB },
            @{ Path = 'C:\Windows';          Size = 600MB }
        )
        $roots = [FolderNodeViewModel]::FromReport($report)

        $roots.Count            | Should -Be 2
        $roots[0].Label         | Should -Be 'C:\Users'
        $roots[0].SizeText      | Should -Be '50 GB'
        $roots[0].IsRoot        | Should -BeTrue
        $roots[0].Depth         | Should -Be 0

        $child = $roots[0].Children[0]
        $child.Label            | Should -Be '\bob\Videos'   # segment relative to shown parent
        $child.Path             | Should -Be 'C:\Users\bob\Videos'
        $child.SizeText         | Should -Be '20 GB'
        $child.IsRoot           | Should -BeFalse
        $child.Depth            | Should -Be 1

        $roots[1].SizeText      | Should -Be '600 MB'
        $roots[1].Children.Count | Should -Be 0
    }

    It "returns an empty array for a null or empty report" {
        @([FolderNodeViewModel]::FromReport($null)).Count | Should -Be 0
        @([FolderNodeViewModel]::FromReport([DiskUsageReport]::new())).Count | Should -Be 0
    }

    Context "clear selection" {
        BeforeEach {
            $script:roots = [FolderNodeViewModel]::FromReport((New-Report @(
                        @{ Path = 'C:\App';   Size = 10GB },
                        @{ Path = 'C:\App\a'; Size = 6GB },
                        @{ Path = 'C:\App\b'; Size = 4GB }
                    )))
            $script:app = $roots[0]
        }

        It "checking a parent cascades to every deletable child and collects the parent" {
            $app.SetChecked($true)
            $app.IsSelected | Should -BeTrue
            ($app.Children | ForEach-Object { $_.IsSelected }) | Should -Be @($true, $true)
            (@([FolderNodeViewModel]::CollectSelected($roots)).Path) | Should -Be 'C:\App'
        }

        It "checking a child never selects the parent - the tree shows only the largest folders" {
            # The roll-up this replaces promoted "all visible children checked" to a checked
            # parent, escalating one child's clear into the parent's entire on-disk contents.
            $a = $app.Children | Where-Object { $_.Path -eq 'C:\App\a' }
            $a.SetChecked($true)

            $app.IsSelected | Should -BeFalse
            (@([FolderNodeViewModel]::CollectSelected($roots)).Path) | Should -Be 'C:\App\a'
        }

        It "unchecking one child releases the checked parent and spares that child" {
            $app.SetChecked($true)
            ($app.Children | Where-Object { $_.Path -eq 'C:\App\a' }).SetChecked($false)

            $app.IsSelected | Should -BeFalse
            ($app.Children | Where-Object { $_.Path -eq 'C:\App\a' }).IsSelected | Should -BeFalse
            # only the still-checked child is collected - the unchecked one is never cleared
            (@([FolderNodeViewModel]::CollectSelected($roots)).Path) | Should -Be 'C:\App\b'
        }

        It "re-checking the spared child collects both children, never the parent" {
            $app.SetChecked($true)
            $a = $app.Children | Where-Object { $_.Path -eq 'C:\App\a' }
            $a.SetChecked($false)
            $a.SetChecked($true)

            $app.IsSelected | Should -BeFalse
            (@([FolderNodeViewModel]::CollectSelected($roots)).Path | Sort-Object) |
                Should -Be @('C:\App\a', 'C:\App\b')
        }
    }
}
