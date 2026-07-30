<#
.SYNOPSIS
    Pure safety policy for the "delete folders" action: which scanned folders may be removed.

.DESCRIPTION
    The delete runs as SYSTEM on the target, so the removable set is gated twice - here (which
    drives the UI checkbox) and again inside the remote script (defence in depth). A folder is
    deletable only when it is a real absolute path that is not the volume root, not the Users
    container itself, and not a protected system directory (or anything under one).

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

    # True when $path is safe to delete: an absolute local path, not the drive root, not the
    # whole Users store, and not a protected system directory - unless it is a known cache above.
    static [bool] IsDeletable([string]$path) {
        if ([string]::IsNullOrWhiteSpace($path)) { return $false }
        $p = $path.Trim().TrimEnd('\')
        # Must be "X:\<something>" - this also rejects the bare volume root "C:\".
        if ($p -notmatch '^[A-Za-z]:\\.+') { return $false }
        $rest = $p.Substring(3).ToLowerInvariant()
        # A known cache (or anything under it) is deletable even beneath a protected root.
        foreach ($c in [FolderDeletionPolicy]::AllowedCaches) {
            if ($rest -eq $c -or $rest.StartsWith("$c\")) { return $true }
        }
        if ($rest -eq 'users') { return $false }
        return -not ([FolderDeletionPolicy]::Protected -contains $rest.Split('\')[0])
    }
}
