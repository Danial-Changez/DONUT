<#
.SYNOPSIS
    Builds the one-line startup provenance stamp (build identity + runtime).

.DESCRIPTION
    A field log is only actionable when it names the exact code that produced it.
    Stamp() returns one pipe-delimited line: the git short SHA and dirty flag when
    the install is a clone, the launcher-written version.txt on prod installs,
    plus the pwsh/CLR versions, machine name and OS build. Logged once right
    after "DONUT starting up." (see DonutApp.ps1).

.NOTES
    Static and logger-free on purpose: DonutApp calls it before most collaborators
    exist, and tools/Invoke-DiagnosticRun.ps1 reuses it for its provenance.json.
#>
class BuildProvenance {

    # One line identifying the build and runtime this process runs on.
    static [string] Stamp([string]$sourceRoot) {
        $build = [BuildProvenance]::DescribeBuild($sourceRoot)
        return "Build: $build | pwsh=$($global:PSVersionTable.PSVersion) | " +
        "clr=$([System.Environment]::Version) | " +
        "host=$([System.Environment]::MachineName) | " +
        "os=$([System.Environment]::OSVersion.VersionString)"
    }

    # Build identity: git SHA (+dirty) on clones, version.txt on prod, else unknown.
    hidden static [string] DescribeBuild([string]$sourceRoot) {
        $note = ''
        try {
            $root = if ($sourceRoot) { Split-Path -Parent $sourceRoot } else { '' }
            $gitDir = if ($root) { Join-Path $root '.git' } else { '' }
            if ($gitDir -and (Test-Path $gitDir) -and
                (Get-Command git -ErrorAction SilentlyContinue)) {
                $sha = & git -C $root rev-parse --short HEAD 2>$null
                if ($global:LASTEXITCODE -eq 0 -and $sha) {
                    $status = & git -C $root status --porcelain 2>$null
                    $dirty = if (@($status).Count -gt 0) { '+dirty' } else { '' }
                    return "commit $sha$dirty"
                }
            }
        }
        catch {
            $note = " (git probe failed: $($_.Exception.Message))"
        }
        try {
            $versionFile = Join-Path (Join-Path $env:LOCALAPPDATA 'DONUT') 'version.txt'
            if (Test-Path $versionFile) {
                $v = [string](Get-Content $versionFile -TotalCount 1 -ErrorAction Stop)
                if ($v.Trim()) { return "version $($v.Trim())$note" }
            }
        }
        catch {
            $note += " (version.txt unreadable: $($_.Exception.Message))"
        }
        return "unknown$note"
    }
}
