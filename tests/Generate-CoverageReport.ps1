param(
    [string]$ReportDir = "$PSScriptRoot\..\CoverageReport"
)

# Ensure STA mode for WPF integration tests
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host "Re-launching in STA mode for WPF tests..." -ForegroundColor Yellow
    pwsh -Sta -File $MyInvocation.MyCommand.Path @PSBoundParameters
    exit
}

# Pester 5+ is required
Import-Module Pester -ErrorAction Stop

# Run Pester with code coverage
Write-Host "Running tests with code coverage..." -ForegroundColor Cyan
$coverageXml = "$PSScriptRoot\..\coverage.xml"

if (-not ([System.Management.Automation.PSTypeName]'PesterConfiguration').Type) {
    Write-Warning "PesterConfiguration type not found. This script requires Pester 5+."
    Throw "Pester 5+ is required for this script."
}
else {
    $config = [PesterConfiguration]::Default
    $config.Run.Path = "$PSScriptRoot"
    $config.CodeCoverage.Enabled = $true
    
    # Specify which folders to cover under 'src'
    $foldersToCover = @(
        "Core",
        "Models",
        "Services"
    )

    $config.CodeCoverage.Path = $foldersToCover | ForEach-Object {
        Get-ChildItem (Join-Path "$PSScriptRoot\..\src" $_) -Recurse -ErrorAction SilentlyContinue
    } | Select-Object -ExpandProperty FullName
    $config.CodeCoverage.OutputFormat = 'JaCoCo'
    $config.CodeCoverage.OutputPath = $coverageXml
    $config.Output.Verbosity = "None"
    $config.Run.PassThru = $true
    
    & Invoke-Pester -Configuration $config
}

# Generate Report using JaCoCo-XML-to-HTML-PowerShell
if (-not (Test-Path $coverageXml)) {
    Write-Error "Coverage XML file was not generated."
}
else {
    Write-Host "Generating HTML report using JaCoCo-XML-to-HTML-PowerShell..." -ForegroundColor Cyan
    $toolPath = "$PSScriptRoot\..\tools\JaCoCoToHtml\constup-jacoco-xml-to-html.ps1"
    
    if (Test-Path $toolPath) {
        $configPath = "$PSScriptRoot\jacoco-config.ps1"
        $sourceDir = Resolve-Path "$PSScriptRoot\..\src"
        
        # Ensure output directory exists and is empty (tool requirement)
        if (Test-Path $ReportDir) {
            Remove-Item "$ReportDir\*" -Recurse -Force
        }
        else {
            New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
        }

        $configContent = @"
`$Global:jacocoxml2htmlConfig = [PSCustomObject]@{
    'xml_file' = '$coverageXml';
    'destination_directory' = '$ReportDir';
    'sources_directory' = '$sourceDir';
    'theme' = 'dark';
}
"@
        Set-Content -Path $configPath -Value $configContent
        & pwsh -File $toolPath --config $configPath
        
        # Clean up config
        Remove-Item $configPath -Force
        $reportPath = Join-Path $ReportDir "index.html"

        if (Test-Path $reportPath) {
            Write-Host "Report generated successfully at: $reportPath" -ForegroundColor Green
            Write-Host "You can open it by pasting your clipboard in the terminal" -ForegroundColor Gray
            Set-Clipboard -Value "Invoke-Item '$reportPath'"
        }
    }
    else {
        Write-Error "JaCoCo-XML-to-HTML-PowerShell tool not found at $toolPath."
    }
}