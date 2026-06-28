using module "..\..\src\Core\HostListSource.psm1"

# Fake that overrides the filesystem seams so path-selection and parsing can be
# exercised off-disk. PathExists consults an in-memory set of "present" paths;
# ReadLines returns canned content keyed by path.
class FakeHostListSource : HostListSource {
    [System.Collections.Generic.HashSet[string]] $Present
    [hashtable] $Contents
    [bool] $ThrowOnRead = $false

    FakeHostListSource([string]$sourceRoot) : base($sourceRoot) {
        $this.Present = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $this.Contents = @{}
    }

    hidden [bool] PathExists([string]$path) {
        return $this.Present.Contains($path)
    }

    hidden [string[]] ReadLines([string]$path) {
        if ($this.ThrowOnRead) { throw "boom" }
        if ($this.Contents.ContainsKey($path)) { return $this.Contents[$path] }
        return @()
    }
}

Describe "HostListSource" {

    BeforeEach {
        # SourceRoot's parent is C:\Repo, so res\WSID.txt resolves under it.
        $script:src = [FakeHostListSource]::new("C:\Repo\src")
        $script:userPath = (Join-Path $env:LOCALAPPDATA "DONUT\config\WSID.txt")
        $script:resPath = (Join-Path "C:\Repo" "res\WSID.txt")
    }

    Context "CandidatePaths" {
        It "Lists the per-user config copy first, then res\WSID.txt" {
            $paths = $script:src.CandidatePaths()
            $paths.Count | Should -Be 2
            $paths[0] | Should -Be $script:userPath
            $paths[1] | Should -Be $script:resPath
        }
    }

    Context "ResolvePath" {
        It "Returns null when no candidate exists" {
            $script:src.ResolvePath() | Should -BeNullOrEmpty
        }

        It "Prefers the per-user config copy when both exist" {
            $script:src.Present.Add($script:userPath) | Out-Null
            $script:src.Present.Add($script:resPath) | Out-Null
            $script:src.ResolvePath() | Should -Be $script:userPath
        }

        It "Falls back to res\WSID.txt when only it exists" {
            $script:src.Present.Add($script:resPath) | Out-Null
            $script:src.ResolvePath() | Should -Be $script:resPath
        }
    }

    Context "ReadHosts" {
        It "Returns an empty array when no file is present" {
            $hosts = $script:src.ReadHosts()
            @($hosts).Count | Should -Be 0
        }

        It "Trims whitespace and drops blank lines" {
            $script:src.Present.Add($script:userPath) | Out-Null
            $script:src.Contents[$script:userPath] = @("  PC-1 ", "", "PC-2", "   ", "`tPC-3")

            $hosts = $script:src.ReadHosts()
            $hosts | Should -Be @("PC-1", "PC-2", "PC-3")
        }

        It "Reads from the resolved (preferred) path only" {
            $script:src.Present.Add($script:userPath) | Out-Null
            $script:src.Present.Add($script:resPath) | Out-Null
            $script:src.Contents[$script:userPath] = @("USER-PC")
            $script:src.Contents[$script:resPath] = @("RES-PC")

            $script:src.ReadHosts() | Should -Be @("USER-PC")
        }

        It "Degrades to an empty array when the read throws" {
            $script:src.Present.Add($script:userPath) | Out-Null
            $script:src.ThrowOnRead = $true

            $hosts = $script:src.ReadHosts()
            @($hosts).Count | Should -Be 0
        }
    }
}
