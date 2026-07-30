<#
.SYNOPSIS
    Pure safety policy for the "delete folders" action: which scanned folders may be removed.

.DESCRIPTION
    The delete runs as SYSTEM on the target, so the removable set is gated twice - here (which
    drives the UI checkbox) and again inside the remote script (defence in depth). A folder is
    deletable only when it is a real absolute path that is not the volume root, not the Users
    container itself, and not a protected system directory (or anything under one).

    Every path is canonicalized first, because the lists here are string comparisons: without it
    "C:\temp\..\Windows\System32" reads as an ordinary "temp" folder and clears System32.

.NOTES
    WPF-free and pure so it is unit-tested headless. Keep this list in sync with the server-side
    re-check in ExecutionService.BuildDeleteCommand.
#>
class FolderDeletionPolicy {
    # First-segment system directories that (with everything under them) are never deletable.
    static [string[]] $Protected = @(
        'windows', 'program files', 'program files (x86)', 'programdata',
        'system volume information', '$recycle.bin', 'recovery', 'perflogs',
        '$winreagent', 'boot', 'msocache', '$sysreset'
    )

    # Known safe-to-clear caches that live under an otherwise-protected root; a folder equal to
    # or under one of these is deletable despite the blocklist (path tail after "X:\", lowercase).
    static [string[]] $AllowedCaches = @(
        'windows\ccmcache',                        # SCCM client package cache
        'windows\temp',                            # system temp
        'windows\softwaredistribution\download',   # Windows Update download cache
        'windows\prefetch',
        'windows\logs',
        'windows\downloaded program files'
    )

    # Resolves "." / ".." and Windows' trailing dot-space stripping without touching the disk, so
    # the lists below can't be walked around ("C:\temp\..\Windows"). $null when the path is unusable.
    static [string] Canonicalize([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $null }
        # Not [IO.Path]::GetFullPath: that is OS-relative, and this class is unit-tested headless.
        $p = $path.Trim().Replace('/', '\')
        if ($p -notmatch '^[A-Za-z]:\\') { return $null }
        $stack = [System.Collections.Generic.List[string]]::new()
        foreach ($raw in $p.Substring(3).Split('\')) {
            if ($raw -eq '' -or $raw -eq '.') { continue }
            if ($raw -eq '..') {
                # Escaping above the volume root is never a real selection - refuse the whole path.
                if ($stack.Count -eq 0) { return $null }
                $stack.RemoveAt($stack.Count - 1)
                continue
            }
            # 8.3 aliases (PROGRA~1) resolve past a long-name blocklist, so they are never accepted.
            if ($raw -match '~\d') { return $null }
            $seg = $raw.TrimEnd(' ', '.')
            if ($seg -eq '') { return $null }
            $stack.Add($seg)
        }
        if ($stack.Count -eq 0) { return $null }
        return $p.Substring(0, 3) + ($stack -join '\')
    }

    # True when $path is safe to delete: an absolute local path, not the drive root, not the
    # whole Users store, and not a protected system directory - unless it is a known cache above.
    static [bool] IsDeletable([string]$path) {
        $p = [FolderDeletionPolicy]::Canonicalize($path)
        if (-not $p) { return $false }
        $rest = $p.Substring(3).ToLowerInvariant()
        # A known cache (or anything under it) is deletable even beneath a protected root.
        foreach ($c in [FolderDeletionPolicy]::AllowedCaches) {
            if ($rest -eq $c -or $rest.StartsWith("$c\")) { return $true }
        }
        if ($rest -eq 'users') { return $false }
        return -not ([FolderDeletionPolicy]::Protected -contains $rest.Split('\')[0])
    }
}
