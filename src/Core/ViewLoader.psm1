<#
.SYNOPSIS
    Loads runtime XAML views from disk (the app's only view loader).

.DESCRIPTION
    Wraps XamlReader.Load with the stream-dispose discipline so .xaml files are
    never left locked on disk. Each returned root owns its file's namescope -
    FindName works on that root and cannot see into other loaded roots, which is
    what keeps composed views (shell + regions, ConfigView + option views) from
    reaching across their seams.

.NOTES
    Throws on a missing or invalid file. Composition call sites (HomePresenter's
    region loading) deliberately let that propagate - a broken region must fail
    the boot loudly - while the page-level callers keep their own catch + null.
#>
class ViewLoader {
    static [object] Load([string]$sourceRoot, [string]$relativePath) {
        $path = Join-Path $sourceRoot $relativePath
        if (-not (Test-Path $path)) {
            throw [System.IO.FileNotFoundException]::new("View not found: $relativePath", $path)
        }
        $stream = [System.IO.File]::OpenRead($path)
        try { return [System.Windows.Markup.XamlReader]::Load($stream) }
        finally { $stream.Dispose() }
    }
}
