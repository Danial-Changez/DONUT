using namespace Donut.Mvvm

<#
.SYNOPSIS
    One tab on the Logs page: a log file's name + its (possibly tail-truncated) text.

.DESCRIPTION
    The TabControl's ItemTemplate binds Header; its ContentTemplate binds Text plus the
    truncation bar (IsTruncated/TruncationNote/LoadFullCommand). Large files start as a
    tail with IsTruncated=$true; LoadFullCommand (assigned by LogsPresenter, which owns
    the file I/O) calls ShowFull with the whole file, which flips the bar off - the
    tail/full pagination behaviour is unchanged, only the rendering moved to bindings.
#>
class LogTabViewModel : ObservableObject {
    [string] $Header = ''
    [string] $Text = ''
    [bool]   $IsTruncated = $false
    [string] $TruncationNote = ''
    [object] $LoadFullCommand   # RelayCommand, assigned by the presenter for large files

    LogTabViewModel([string]$header, [string]$text) {
        $this.Header = $header
        $this.Text = $text
    }

    # Replaces the tail with the full file content and hides the truncation bar.
    [void] ShowFull([string]$fullText) {
        $this.Set('Text', $fullText)
        $this.Set('IsTruncated', $false)
    }
}
