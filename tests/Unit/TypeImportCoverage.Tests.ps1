<#
    Regression guard for the "works on Linux, breaks on Windows" import class of bug:
    a file calls [SomeProjectClass]:: while relying on a TRANSITIVE using-module chain
    to resolve it. That resolution is load-order luck, and the WPF-blocked files where
    it breaks are exactly the ones the Linux suite can never compile (the TimeFormat /
    InventoryPresenter field failure). Text-level, so it runs everywhere.
#>

Describe "Project type import coverage" {

    BeforeAll {
        $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../src'))
        $script:Files = Get-ChildItem -Path $script:SrcRoot -Recurse -Include '*.psm1', '*.ps1' -File

        # class name -> defining module file basename(s), from `class X` declarations.
        $script:DefinedIn = @{}
        foreach ($f in $script:Files | Where-Object Extension -EQ '.psm1') {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $f.FullName -Raw),
                    '(?m)^class\s+(\w+)')) {
                $cls = $m.Groups[1].Value
                if (-not $script:DefinedIn.ContainsKey($cls)) { $script:DefinedIn[$cls] = @() }
                $script:DefinedIn[$cls] += $f.Name
            }
        }
    }

    It "every [ProjectClass]:: usage imports the defining module directly" {
        $violations = @()
        foreach ($f in $script:Files) {
            $text = Get-Content -LiteralPath $f.FullName -Raw
            foreach ($cls in $script:DefinedIn.Keys) {
                if ($script:DefinedIn[$cls] -contains $f.Name) { continue }   # defined here
                if ($text -notmatch "\[$([regex]::Escape($cls))\]::") { continue }
                $importsAny = $false
                foreach ($def in $script:DefinedIn[$cls]) {
                    if ($text -match "using module\s+[""'].*$([regex]::Escape($def))[""']") {
                        $importsAny = $true; break
                    }
                }
                if (-not $importsAny) {
                    $violations += "$($f.Name) uses [$cls]:: but never imports $($script:DefinedIn[$cls] -join '/')"
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because (
            'transitive type resolution is load-order luck, and it breaks first in the ' +
            'WPF files the Linux suite cannot compile (the InventoryPresenter/TimeFormat field failure)')
    }
}
