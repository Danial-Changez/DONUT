#Requires -Version 7.0
<#
.SYNOPSIS
    Renders docs/diagrams/*.puml to SVG for the documentation site.

.DESCRIPTION
    Downloads a pinned PlantUML jar on first use (cached under tools/.cache, gitignored),
    then renders every .puml under docs/diagrams into web/public/diagrams (gitignored;
    the site serves them at /DONUT/diagrams/<name>.svg). Prefers Graphviz dot for layout
    and falls back to PlantUML's built-in Smetana engine when dot is absent. Run locally
    after editing a diagram; the docs CI workflow runs this same script on ubuntu.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$plantUmlVersion = '1.2026.6'
$repoRoot = Split-Path -Parent $PSScriptRoot
$cacheDir = Join-Path $PSScriptRoot '.cache'
$jarPath = Join-Path $cacheDir "plantuml-$plantUmlVersion.jar"
$sourceDir = Join-Path $repoRoot 'docs/diagrams'
$outputDir = Join-Path $repoRoot 'web/public/diagrams'

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    throw 'java was not found on PATH. Install a JDK/JRE (any recent version works).'
}

if (-not (Test-Path $jarPath)) {
    New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
    $url = "https://github.com/plantuml/plantuml/releases/download/v$plantUmlVersion/plantuml-$plantUmlVersion.jar"
    Write-Host "Downloading PlantUML $plantUmlVersion..."
    Invoke-WebRequest -Uri $url -OutFile $jarPath
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

# Without Graphviz, Smetana keeps local renders working (CI apt-installs dot for parity).
$layoutArgs = @()
if (-not (Get-Command dot -ErrorAction SilentlyContinue)) {
    Write-Warning 'Graphviz "dot" not found; using Smetana layout. Install Graphviz (winget install Graphviz.Graphviz) to match CI output exactly.'
    $layoutArgs = @('-Playout=smetana')
}

$pumlFiles = Get-ChildItem -Path $sourceDir -Filter '*.puml'
java -jar $jarPath -tsvg -charset UTF-8 @layoutArgs -o $outputDir $pumlFiles.FullName
if ($LASTEXITCODE -ne 0) {
    throw "PlantUML exited with code $LASTEXITCODE."
}

Write-Host "Rendered $($pumlFiles.Count) diagram(s) to $outputDir"
