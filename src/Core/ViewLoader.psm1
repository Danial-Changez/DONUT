<#
.SYNOPSIS
    Loads runtime XAML views (the app's only view loader).

.DESCRIPTION
    Wraps XamlReader.Load with the stream-dispose discipline. Hosted by the
    launcher, views come from the assembly's embedded copy - the XAML never has
    to exist on disk; a dev run (plain pwsh over the checkout) falls back to the
    file under SourceRoot. Each returned root owns its file's namescope -
    FindName works on that root and cannot see into other loaded roots, which is
    what keeps composed views (shell + regions, the settings option views) from
    reaching across their seams.

.NOTES
    Throws on a missing or invalid view. Composition call sites (HomePresenter's
    region loading) deliberately let that propagate - a broken region must fail
    the boot loudly - while the page-level callers keep their own catch + null.
#>
class ViewLoader {
    # Streams the launcher's embedded copy when that type is loaded (prod), else
    # the file under SourceRoot (dev).
    static [object] Load([string]$sourceRoot, [string]$relativePath) {
        $stream = $null
        $assets = 'Donut.Launcher.EmbeddedAssets' -as [type]
        if ($assets) {
            $stream = $assets::Open('src/' + ($relativePath -replace '\\', '/'))
        }
        if (-not $stream) {
            $path = Join-Path $sourceRoot $relativePath
            if (-not (Test-Path $path)) {
                throw [System.IO.FileNotFoundException]::new("View not found: $relativePath", $path)
            }
            $stream = [System.IO.File]::OpenRead($path)
        }
        try { return [System.Windows.Markup.XamlReader]::Load($stream) }
        finally { $stream.Dispose() }
    }
}
