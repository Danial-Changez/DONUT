# Loads a XAML file from a relative path and returns the parsed WPF object.
# - Validates file existence and handles errors.
# - Returns the loaded object or $null on failure.
Function Import-Xaml {
    param (
        [string]$RelativePath
    )
    $fullPath = Join-Path $PSScriptRoot $RelativePath
    if (-not (Test-Path $fullPath)) {
        Write-Host "[ERROR] XAML file not found: $fullPath" -ForegroundColor Red
        return $null
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        return [Windows.Markup.XamlReader]::Load($stream)
    }
    catch {
        Write-Host "[ERROR] Failed to load XAML file: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
    finally {
        $stream.Close()
    }
}

# Loads a XAML view from a relative path and returns the parsed WPF object.
# - Validates file existence and handles errors.
# - Returns the loaded view object or $null on failure.
Function Import-XamlView {
    param([string]$RelativePath)
    $fullPath = Join-Path $PSScriptRoot $RelativePath
    if (-not (Test-Path $fullPath)) {
        Write-Host "File not found: $fullPath"
        return $null
    }
    $stream = [System.IO.File]::OpenRead($fullPath)
    try {
        $xaml = [Windows.Markup.XamlReader]::Load($stream)
        return $xaml
    }
    catch {
        Write-Host "Failed to load XAML file: $($_.Exception.Message)"
        return $null
    }
    finally {
        $stream.Close()
    }
}
