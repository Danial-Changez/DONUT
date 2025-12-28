using namespace System.Windows

class ResourceService {
    [string]$SourceRoot

    ResourceService([string]$sourceRoot) {
        $this.SourceRoot = $sourceRoot
    }

    # Loads all styles into the global Application scope
    [void] LoadGlobalResources() {
        if (-not [System.Windows.Application]::Current) {
            try {
                # Use New-Object with ErrorAction Stop to ensure it's catchable
                $app = New-Object System.Windows.Application -ErrorAction Stop
                $app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                Write-Host "Created Application. ShutdownMode: $($app.ShutdownMode)"
            }
            catch {
                Write-Warning "Unable to create WPF Application object (one may already exist in this AppDomain on another thread): $_"
            }
        }
        
        if ([System.Windows.Application]::Current) {
            if ([System.Windows.Application]::Current.ShutdownMode -ne [System.Windows.ShutdownMode]::OnExplicitShutdown) {
                [System.Windows.Application]::Current.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
                Write-Host "Updated ShutdownMode to: $([System.Windows.Application]::Current.ShutdownMode)"
            }
            $this.LoadStylesInto([System.Windows.Application]::Current.Resources)
            Write-Host "App.Current Resources MergedDictionaries Count: $([System.Windows.Application]::Current.Resources.MergedDictionaries.Count)"
            if ([System.Windows.Application]::Current.Resources.MergedDictionaries.Count -eq 0) {
                 [System.Windows.Forms.MessageBox]::Show("Warning: No resources loaded into App.Current", "Debug")
            }
        }
        else {
            Write-Warning "Skipping global resource loading because Application.Current is not accessible."
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
            Write-Warning "Styles folder not found at $stylesPath"
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
                Write-Warning "Failed to load style: $($_.Name) - $_"
                [System.Windows.Forms.MessageBox]::Show("Failed to load style: $($_.Name)`n$_", "Resource Error")
            }
        }
    }
}
