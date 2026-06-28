using namespace System.Windows
using module "..\Core\LogService.psm1"

class ResourceService {
    [string]$SourceRoot
    [LogService]$Logger

    ResourceService([string]$sourceRoot) {
        $this.SourceRoot = $sourceRoot
        $this.Logger = [NullLogService]::new()
    }

    ResourceService([string]$sourceRoot, [LogService]$logger) {
        $this.SourceRoot = $sourceRoot
        if ($null -eq $logger) {
            $this.Logger = [NullLogService]::new()
        }
        else {
            $this.Logger = $logger
        }
    }

    # Loads all styles into the global Application scope
    [void] LoadGlobalResources() {
        if (-not [System.Windows.Application]::Current) {
            try {
                # Use New-Object with ErrorAction Stop to ensure it's catchable
                $app = New-Object System.Windows.Application -ErrorAction Stop
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                $this.Logger.LogDebug("Created WPF Application. ShutdownMode: $($app.ShutdownMode)")
            }
            catch {
                $this.Logger.LogWarning("Unable to create WPF Application object (one may already exist in this AppDomain on another thread): $($_.Exception.Message)")
            }
        }
        
        if ([System.Windows.Application]::Current) {
            if ([System.Windows.Application]::Current.ShutdownMode -ne [System.Windows.ShutdownMode]::OnExplicitShutdown) {
                [System.Windows.Application]::Current.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                $this.Logger.LogDebug("Updated ShutdownMode to: $([System.Windows.Application]::Current.ShutdownMode)")
            }
            $this.LoadStylesInto([System.Windows.Application]::Current.Resources)
            $dictCount = [System.Windows.Application]::Current.Resources.MergedDictionaries.Count
            $this.Logger.LogDebug("App.Current Resources MergedDictionaries Count: $dictCount")
            if ($dictCount -eq 0) {
                $this.Logger.LogWarning("No resources loaded into App.Current.")
            }
        }
        else {
            $this.Logger.LogWarning("Skipping global resource loading because Application.Current is not accessible.")
        }
    }

    # Applies loaded styles to a specific window (needed for XamlReader loaded windows)
    [void] ApplyResourcesToWindow([Window]$window) {
        if ([System.Windows.Application]::Current) {
            # Merge dictionaries from App.Current to Window
            foreach ($dict in [System.Windows.Application]::Current.Resources.MergedDictionaries) {
                $window.Resources.MergedDictionaries.Add($dict)
            }
        }
        else {
            # Fallback if App.Current isn't set
            $this.LoadStylesInto($window.Resources)
        }
    }

    hidden [void] LoadStylesInto([ResourceDictionary]$targetDictionary) {
        $stylesPath = Join-Path $this.SourceRoot 'UI\Styles'
        
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
            }
            catch {
                $this.Logger.LogException("Failed to load style dictionary", $_)
            }
        }
    }
}
