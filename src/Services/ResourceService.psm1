using namespace System.Windows
using module "..\Core\LogService.psm1"

<#
.SYNOPSIS
    Loads and applies the app's merged XAML resource dictionaries.

.DESCRIPTION
    Merges every *.xaml under src/UI/Styles into one ResourceDictionary (colours,
    button styles, control templates, icons) and applies it to a window so views
    can resolve the shared DynamicResource keys.

.NOTES
    Hosted by the launcher, the dictionaries are read from the embedded copy and the
    XAML never touches disk, while a dev run reads the checkout files. Either way the
    ParserContext BaseUri must stay a path to a file in UI\Styles: the dictionaries
    reference their fonts relatively (./Fonts/...) and those ttf files are always on
    disk, so a BaseUri pointing anywhere else silently loses every custom font.
#>
class ResourceService {
    [string]$SourceRoot
    [LogService]$Logger

    ResourceService([string]$sourceRoot) {
        $this.SourceRoot = $sourceRoot
        $this.Logger = [NullLogService]::new()
    }

    ResourceService([string]$sourceRoot, [LogService]$logger) {
        $this.SourceRoot = $sourceRoot
        $this.Logger = [LogService]::Coalesce($logger)
    }

    [void] LoadGlobalResources() {
        if (-not [System.Windows.Application]::Current) {
            try {
                # -ErrorAction Stop so a construction failure is catchable.
                $app = New-Object System.Windows.Application -ErrorAction Stop
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                $this.Logger.LogDebug("Created WPF Application. ShutdownMode: $($app.ShutdownMode)")
            } catch {
                $this.Logger.LogWarning("Unable to create WPF Application object " +
                    "(one may already exist in this AppDomain on another thread): $($_.Exception.Message)")
            }
        }

        $current = [System.Windows.Application]::Current
        if ($current) {
            if ($current.ShutdownMode -ne [System.Windows.ShutdownMode]::OnExplicitShutdown) {
                $current.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                $this.Logger.LogDebug("Updated ShutdownMode to: $($current.ShutdownMode)")
            }
            $this.LoadStylesInto($current.Resources)
        } else {
            $this.Logger.LogWarning("Skipping global resource loading because Application.Current is not accessible.")
        }
    }

    # XamlReader-loaded windows do not inherit the application's merged dictionaries.
    [void] ApplyResourcesToWindow([Window]$window) {
        if ([System.Windows.Application]::Current) {
            foreach ($dict in [System.Windows.Application]::Current.Resources.MergedDictionaries) {
                $window.Resources.MergedDictionaries.Add($dict)
            }
        } else {
            $this.LoadStylesInto($window.Resources)
        }
    }

    hidden [void] LoadStylesInto([ResourceDictionary]$targetDictionary) {
        $stylesPath = Join-Path $this.SourceRoot 'UI\Styles'

        # BaseUri must stay a path to a file in UI\Styles either way. See .NOTES.
        $assets = 'Donut.Launcher.EmbeddedAssets' -as [type]
        if ($assets) {
            $names = @($assets::List('src/UI/Styles/') |
                    Where-Object { $_ -like '*.xaml' } | Sort-Object)
            foreach ($logical in $names) {
                try {
                    $leaf = [System.IO.Path]::GetFileName($logical)
                    $context = [System.Windows.Markup.ParserContext]::new()
                    $context.BaseUri = [Uri]::new((Join-Path $stylesPath $leaf))
                    # A try-only assignment reads as unassigned to the class runtime.
                    $dict = $null
                    $stream = $assets::Open($logical)
                    try { $dict = [System.Windows.Markup.XamlReader]::Load($stream, $context) }
                    finally { $stream.Dispose() }
                    $targetDictionary.MergedDictionaries.Add($dict)
                } catch {
                    $this.Logger.LogException("Failed to load style dictionary $logical", $_)
                }
            }
            return
        }

        if (-not (Test-Path $stylesPath)) {
            $this.Logger.LogWarning("Styles folder not found at $stylesPath")
            return
        }

        Get-ChildItem -Path $stylesPath -Filter '*.xaml' | ForEach-Object {
            try {
                $context = New-Object System.Windows.Markup.ParserContext
                $context.BaseUri = [Uri]::new($_.FullName)

                $stream = [System.IO.File]::OpenRead($_.FullName)
                $dict = [System.Windows.Markup.XamlReader]::Load($stream, $context)
                $stream.Close()

                $targetDictionary.MergedDictionaries.Add($dict)
            } catch {
                $this.Logger.LogException("Failed to load style dictionary", $_)
            }
        }
    }
}
