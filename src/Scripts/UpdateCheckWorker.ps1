<#
.SYNOPSIS
    Runspace-pool worker that runs the read-only self-update discovery off the UI thread.

.DESCRIPTION
    Invoked once at startup, after the main window has rendered, so the GitHub round-trip
    never blocks the window from appearing. Reads the installed version, the stored
    device-flow token, and - when a token exists - the latest release, and returns them
    as a hashtable for UpdatePresenter to compare + prompt on the dispatcher. The
    download / verify / apply still happen on the main thread (UpdatePresenter), unchanged.

.NOTES
    Read-only: it never downloads, installs, prompts, or performs the device-flow login
    (that stays on the UI thread). Runs on a pool runspace, never the WPF dispatcher.
#>
using module "..\Services\SelfUpdateService.psm1"

$ErrorActionPreference = 'Stop'

try {
    $svc = [SelfUpdateService]::new()
    $local = $svc.GetLocalVersion()
    $token = $svc.GetStoredToken()

    # No token yet: report back so the presenter can run the device-flow login on the
    # UI thread, then re-kick this worker. We can't discover releases without a token.
    if ([string]::IsNullOrEmpty($token)) {
        return @{ HasToken = $false; LocalVersion = $local }
    }

    $release = $svc.GetLatestRelease($token)
    return @{
        HasToken     = $true
        LocalVersion = $local
        Release      = $release
        TagName      = if ($release) { [string]$release.tag_name } else { '' }
    }
}
catch {
    # HasToken=$true so the presenter just logs and stops (no spurious login prompt).
    return @{ HasToken = $true; Error = "$_" }
}
