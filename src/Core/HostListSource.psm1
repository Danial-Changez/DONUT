# HostListSource
#
# Resolves the WSID.txt host list shared by the Home and Battery presenters.
# Both used to inline the same candidate-path array (per-user config copy first,
# then the repo's res\WSID.txt) and the same read/trim/filter. That logic now
# lives here, WPF-free and unit-testable.
#
# The filesystem touch points are isolated in overridable seam methods
# (PathExists, ReadLines) mirroring NetworkProbe/SystemInfoService, so the
# path-selection and parsing can be exercised off-disk by subclassing this type
# and faking those seams. ReadHosts returns a trimmed, blank-free string[].

class HostListSource {
    hidden [string] $SourceRoot

    HostListSource([string]$sourceRoot) {
        $this.SourceRoot = $sourceRoot
    }

    # Candidate WSID.txt locations, in priority order: the per-user config copy
    # under LOCALAPPDATA, then the repo's res\WSID.txt (sibling of SourceRoot).
    [string[]] CandidatePaths() {
        return @(
            (Join-Path $env:LOCALAPPDATA "DONUT\config\WSID.txt"),
            (Join-Path (Split-Path $this.SourceRoot -Parent) "res\WSID.txt")
        )
    }

    # Returns the first candidate path that exists, or $null when none do.
    [string] ResolvePath() {
        foreach ($candidate in $this.CandidatePaths()) {
            if ($this.PathExists($candidate)) { return $candidate }
        }
        return $null
    }

    # Returns the trimmed, blank-free list of host names from the first available
    # WSID.txt, or an empty array when no file exists or the read fails.
    [string[]] ReadHosts() {
        $path = $this.ResolvePath()
        if (-not $path) { return @() }
        try {
            return @(
                $this.ReadLines($path) |
                    ForEach-Object { if ($null -ne $_) { $_.Trim() } } |
                    Where-Object { $_ }
            )
        } catch {
            Write-Warning "Failed to load WSID.txt: $_"
            return @()
        }
    }

    # --- Overridable seams (raw filesystem; faked in unit tests) ----------------------

    hidden [bool] PathExists([string]$path) {
        return [bool](Test-Path $path)
    }

    hidden [string[]] ReadLines([string]$path) {
        return @(Get-Content -Path $path)
    }
}
