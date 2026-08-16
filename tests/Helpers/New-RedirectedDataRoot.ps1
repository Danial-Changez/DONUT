# Shared env redirection so tests exercise real data root code without touching real state.

# Points the data root env vars at a fresh directory and returns a handle for restore.
function New-RedirectedDataRoot {
    param(
        [string] $Prefix = 'DonutTests',
        [string] $Under = $env:TEMP,
        [switch] $ProgramDataOnly
    )
    $root = Join-Path $Under "${Prefix}_$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $handle = [pscustomobject]@{
        Root                 = $root
        OriginalProgramData  = $env:ProgramData
        OriginalLocalAppData = $env:LOCALAPPDATA
        ProgramDataOnly      = [bool] $ProgramDataOnly
    }
    $env:ProgramData = $root
    if (-not $ProgramDataOnly) { $env:LOCALAPPDATA = $root }
    return $handle
}

# Restores the redirected env vars and deletes the temporary root.
function Remove-RedirectedDataRoot {
    param([Parameter(Mandatory)] $Handle)
    $env:ProgramData = $Handle.OriginalProgramData
    if (-not $Handle.ProgramDataOnly) { $env:LOCALAPPDATA = $Handle.OriginalLocalAppData }
    Remove-Item -Path $Handle.Root -Recurse -Force -ErrorAction SilentlyContinue
}
