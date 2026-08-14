using module "..\..\src\Core\BuildProvenance.psm1"

<#
    BuildProvenance stamps the startup log with the exact code + runtime a field
    log came from. Contract: a clone yields the git SHA, a non-repo never throws,
    and the runtime facts (pwsh/host) are always present.
#>
Describe "BuildProvenance" {

    BeforeDiscovery {
        # -Skip evaluates at discovery, before any BeforeAll runs.
        $script:HasGit = $null -ne (Get-Command git -ErrorAction SilentlyContinue)
    }

    BeforeAll {
        $script:SrcRoot = (Resolve-Path "$PSScriptRoot\..\..\src").Path
    }

    It "stamps the repo's short SHA when run from a clone" -Skip:(-not $script:HasGit) {
        $repoRoot = Split-Path -Parent $script:SrcRoot
        $sha = (& git -C $repoRoot rev-parse --short HEAD).Trim()
        [BuildProvenance]::Stamp($script:SrcRoot) | Should -Match "commit $sha"
    }

    It "never throws outside a repo and still reports the runtime" {
        # TestDrive sits under the system temp dir, so no enclosing repo answers the SHA probe.
        $root = Join-Path $TestDrive ("DonutProv-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'src') | Out-Null

        $stamp = [BuildProvenance]::Stamp((Join-Path $root 'src'))

        $stamp | Should -Not -BeNullOrEmpty
        $stamp | Should -Match 'pwsh='
        $stamp | Should -Match 'clr='
    }

    It "always names the machine the log came from" {
        [BuildProvenance]::Stamp($script:SrcRoot) |
            Should -Match "host=$([regex]::Escape([System.Environment]::MachineName))"
    }

    It "tolerates an empty source root" {
        { [BuildProvenance]::Stamp('') } | Should -Not -Throw
    }
}
