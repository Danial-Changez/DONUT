using module "..\Core\DonutPaths.psm1"
using module "..\Core\LogService.psm1"
using module "..\Models\PendingIntent.psm1"

<#
.SYNOPSIS
    Persists the one pending elevation intent across a restart, and takes it back once.

.DESCRIPTION
    A gated action clicked without administrator rights writes a note here, DONUT
    relaunches elevated, and the new instance claims the note and re-runs the action.

.NOTES
    Take() deletes the file before it returns anything, so a note fires at most once
    even if the resume then throws: a stale note that survived would re-fire a fleet
    action on every launch. The read is untrusted (a de-elevated process wrote it), so
    the parse lives in PendingIntent.FromJson, which yields $null rather than throwing.
    The file I/O is isolated in overridable seams for off-disk tests.
#>
class PendingIntentStore {
    [LogService] $Logger
    [timespan] $Ttl = [timespan]::FromMinutes(2)

    PendingIntentStore([LogService]$logger) {
        $this.Logger = [LogService]::Coalesce($logger)
    }

    [string] IntentPath() {
        return (Join-Path ([DonutPaths]::DataRoot()) 'pending-intent.json')
    }

    [void] Save([PendingIntent]$intent) {
        if ($null -eq $intent) { return }
        try {
            $this.WriteText($this.IntentPath(), $intent.ToJson())
        } catch {
            # Losing the note costs a re-click after elevating, never correctness.
            $this.Logger.LogWarning("Could not record the pending action: $($_.Exception.Message)")
        }
    }

    # Claims the note: reads, deletes, then validates. Returns $null unless it is
    # parseable, fresh and resumable, so every rejected case behaves identically.
    [PendingIntent] Take([datetime]$nowUtc) {
        $path = $this.IntentPath()
        if (-not $this.FileExists($path)) { return $null }

        $json = ''
        try { $json = $this.ReadText($path) }
        catch { $this.Logger.LogWarning("Could not read the pending action: $($_.Exception.Message)") }
        $this.Discard()

        $intent = [PendingIntent]::FromJson($json)
        if ($null -eq $intent) {
            $this.Logger.LogWarning('Discarded an unreadable pending action.')
            return $null
        }
        if (-not $intent.IsFresh($nowUtc, $this.Ttl)) {
            $this.Logger.LogInfo("Discarded a stale pending $($intent.Action) action.")
            return $null
        }
        if (-not $intent.IsResumable()) {
            $this.Logger.LogInfo(
                "A pending $($intent.Action) action is not resumed automatically; re-run it from the pane.")
            return $null
        }
        return $intent
    }

    [void] Discard() {
        try { $this.DeleteFile($this.IntentPath()) }
        catch { $this.Logger.LogWarning("Could not clear the pending action: $($_.Exception.Message)") }
    }

    # --- Filesystem seams (overridden by the test fake) ---

    hidden [bool] FileExists([string]$path) { return (Test-Path -LiteralPath $path) }
    hidden [string] ReadText([string]$path) {
        return (Get-Content -LiteralPath $path `
                            -Raw `
                            -ErrorAction Stop)
    }

    hidden [void] WriteText([string]$path, [string]$text) {
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory `
                     -Path $dir `
                     -Force | Out-Null
        }
        Set-Content -LiteralPath $path `
                    -Value $text `
                    -Encoding UTF8 `
                    -ErrorAction Stop
    }

    hidden [void] DeleteFile([string]$path) {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}
