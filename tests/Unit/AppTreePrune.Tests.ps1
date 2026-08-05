# The extractor prunes whatever it did not embed, and WizTree is downloaded rather
# than embedded, so a missing keep entry would delete it on every launch.
BeforeAll {
    $script:dll = Get-ChildItem "$PSScriptRoot\..\..\src\Launcher\bin" -Recurse `
        -Filter 'Donut.Launcher.dll' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($script:dll) {
        $asm = [Reflection.Assembly]::LoadFrom($script:dll.FullName)
        $script:prune = $asm.GetType('Donut.Launcher.Program').GetMethod(
            'PruneUnknown', [Reflection.BindingFlags]'NonPublic,Static')
        $script:wizPath = $asm.GetType('Donut.Launcher.Bootstrap').GetMethod('WizTreePath')
    }
}

Describe 'App tree pruning' {
    BeforeEach {
        $script:root = Join-Path ([IO.Path]::GetTempPath()) "donut-prune-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
    }
    AfterEach {
        Remove-Item $script:root -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'spares the downloaded WizTree and deletes what is no longer embedded' {
        if (-not $script:dll) { Set-ItResult -Skipped -Because 'the launcher is not built'; return }

        $wiz = [string]$script:wizPath.Invoke($null, [object[]]@([string]$script:root))
        New-Item -ItemType Directory -Path (Split-Path $wiz -Parent) -Force | Out-Null
        Set-Content -LiteralPath $wiz -Value 'scanner'
        $stale = Join-Path $script:root 'src\Old\dropped.psm1'
        New-Item -ItemType Directory -Path (Split-Path $stale -Parent) -Force | Out-Null
        Set-Content -LiteralPath $stale -Value 'stale'

        # The keep set Program builds: embedded resources plus the WizTree path.
        $keep = [Collections.Generic.HashSet[string]]::new(
            [StringComparer]::OrdinalIgnoreCase)
        [void]$keep.Add([IO.Path]::GetFullPath($wiz))
        $script:prune.Invoke($null, [object[]]@([string]$script:root, $keep))

        Test-Path $wiz | Should -BeTrue -Because 'a downloaded tool must survive extraction'
        Test-Path $stale | Should -BeFalse -Because 'files no longer embedded are pruned'
    }

    It 'deletes WizTree when the keep entry is missing' {
        if (-not $script:dll) { Set-ItResult -Skipped -Because 'the launcher is not built'; return }

        $wiz = [string]$script:wizPath.Invoke($null, [object[]]@([string]$script:root))
        New-Item -ItemType Directory -Path (Split-Path $wiz -Parent) -Force | Out-Null
        Set-Content -LiteralPath $wiz -Value 'scanner'

        $empty = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $script:prune.Invoke($null, [object[]]@([string]$script:root, $empty))

        # Proves the first test is load-bearing rather than passing by accident.
        Test-Path $wiz | Should -BeFalse
    }
}
