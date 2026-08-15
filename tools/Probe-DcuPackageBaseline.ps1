#Requires -Version 5.1
<#
.SYNOPSIS
    Probes every on-box source that could name an installed DCU package version.

.DESCRIPTION
    Run in an elevated PowerShell on a fleet machine that has Dell Command Update.
    Everything is a read-only look at files, logs and registry values. Package-type
    updates (Intel ME Components, dock firmware, SupportAssist) version by package,
    not by any single PnP driver, so their cards currently show only the new
    version. This walks the candidate baseline sources in rank order:

      1. dcu-cli itself: its command surface has no installed-inventory dump.
      2. The newest scan report in C:\temp\DONUT: lists every element the report
         really carries, which confirms no installed version ships in it.
      3. ActivityLog.xml: DCU's own history of what it applied, versions included.
      4. UpdatePackage\Log: one log per Dell Update Package ever run on the box.
      5. UpdateService data dir: checks whether any scan inventory XML persists.
      6. Add or Remove Programs registry: suites that register (ME Components
         does) carry a DisplayVersion in the same scheme DCU's catalog uses.

    The Interpretation footer maps what you see to the enrichment it would fund.

.EXAMPLE
    powershell -File tools\Probe-DcuPackageBaseline.ps1
#>
[CmdletBinding()]
param(
    [string] $ReportDir = 'C:\temp\DONUT'
)

Write-Host 'DONUT DCU package baseline probe (read-only)' -ForegroundColor White

Write-Host "`n=== 1. dcu-cli presence and version ===" -ForegroundColor Cyan
$dcu = @('C:\Program Files (x86)\Dell\CommandUpdate\dcu-cli.exe',
    'C:\Program Files\Dell\CommandUpdate\dcu-cli.exe') |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($dcu) {
    Write-Host "  OK  $dcu" -ForegroundColor Green
    try { & $dcu /version 2>&1 | Select-Object -First 3 | ForEach-Object { Write-Host "  $_" } }
    catch { Write-Host "  /version failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}
else { Write-Host '  dcu-cli not found on this machine' -ForegroundColor Yellow }

Write-Host "`n=== 2. Newest scan report in $ReportDir ===" -ForegroundColor Cyan
$report = $null
if (Test-Path -LiteralPath $ReportDir) {
    $report = Get-ChildItem -Path $ReportDir -Filter '*.xml' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
if ($report) {
    Write-Host "  OK  $($report.Name) ($($report.LastWriteTime))" -ForegroundColor Green
    try {
        [xml]$x = Get-Content -LiteralPath $report.FullName
        $updates = @($x.SelectNodes('//update'))
        # The element inventory proves whether any installed or current field exists at all.
        $elements = $updates | ForEach-Object { $_.ChildNodes } |
            Where-Object { $_.NodeType -eq 'Element' } |
            ForEach-Object { $_.Name } | Sort-Object -Unique
        Write-Host "  update elements: $($elements -join ', ')"
        $updates | ForEach-Object {
            [pscustomobject]@{
                Name     = $_.SelectSingleNode('name').InnerText
                Type     = "$($_.SelectSingleNode('type').InnerText)"
                Category = "$($_.SelectSingleNode('category').InnerText)"
                Version  = "$($_.SelectSingleNode('version').InnerText)"
            }
        } | Format-Table -AutoSize | Out-String | Write-Host
    }
    catch { Write-Host "  parse failed: $($_.Exception.Message)" -ForegroundColor Yellow }
}
else { Write-Host '  no report found (run a DONUT scan first)' -ForegroundColor Yellow }

Write-Host "`n=== 3. DCU ActivityLog.xml (apply history) ===" -ForegroundColor Cyan
$activity = @("$env:ProgramData\Dell\UpdateService\Log\ActivityLog.xml",
    "$env:ProgramData\Dell\CommandUpdate\ActivityLog.xml") |
    Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if ($activity) {
    $item = Get-Item -LiteralPath $activity
    Write-Host "  OK  $activity ($([Math]::Round($item.Length / 1KB)) KB, $($item.LastWriteTime))" -ForegroundColor Green
    # Text matching keeps the probe schema-proof across DCU versions.
    $hits = @(Select-String -LiteralPath $activity -Pattern 'version' -SimpleMatch |
            Select-Object -Last 15)
    Write-Host "  last lines mentioning a version ($($hits.Count) shown):"
    $hits | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
}
else { Write-Host '  no ActivityLog.xml under UpdateService\Log or CommandUpdate' -ForegroundColor Yellow }

Write-Host "`n=== 4. Dell Update Package logs ===" -ForegroundColor Cyan
$dupDir = "$env:ProgramData\Dell\UpdatePackage\Log"
if (Test-Path -LiteralPath $dupDir) {
    $logs = Get-ChildItem -Path $dupDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
    Write-Host "  OK  $($logs.Count) log(s)" -ForegroundColor Green
    $logs | Select-Object -First 15 | Format-Table Name, LastWriteTime -AutoSize | Out-String | Write-Host
    foreach ($log in ($logs | Select-Object -First 5)) {
        $lines = @(Select-String -LiteralPath $log.FullName -Pattern 'version' |
                Select-Object -First 3)
        if ($lines) {
            Write-Host "  $($log.Name):"
            $lines | ForEach-Object { Write-Host "    $($_.Line.Trim())" }
        }
    }
}
else { Write-Host "  $dupDir not present" -ForegroundColor Yellow }

Write-Host "`n=== 5. UpdateService data dir (persisted inventory?) ===" -ForegroundColor Cyan
$svcDir = "$env:ProgramData\Dell\UpdateService"
if (Test-Path -LiteralPath $svcDir) {
    Get-ChildItem -Path $svcDir -Filter '*.xml' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 20 |
        Format-Table @{ n = 'Path'; e = { $_.FullName.Substring($svcDir.Length + 1) } },
        @{ n = 'KB'; e = { [Math]::Round($_.Length / 1KB) } }, LastWriteTime -AutoSize |
        Out-String | Write-Host
}
else { Write-Host "  $svcDir not present" -ForegroundColor Yellow }

Write-Host "`n=== 6. Add or Remove Programs (package suites) ===" -ForegroundColor Cyan
$arp = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*') |
    ForEach-Object { Get-ItemProperty -Path $_ -ErrorAction SilentlyContinue } |
    Where-Object { $_.DisplayName -match 'Dell|Intel|Realtek|Killer|Waves|Thunderbolt|NVIDIA' } |
    Sort-Object DisplayName -Unique
if ($arp) {
    $arp | Format-Table DisplayName, DisplayVersion, Publisher -AutoSize | Out-String | Write-Host
}
else { Write-Host '  no matching entries' -ForegroundColor Yellow }

Write-Host "`n=== Interpretation ===" -ForegroundColor Cyan
Write-Host @'
  2. If the update elements list shows no installed or current field, the scan
     report alone can never provide a package baseline (expected).
  3. ActivityLog version lines mean DCU history can back-fill "last applied"
     for packages, but only ones DCU itself installed since imaging.
  4. DUP logs cover manually run packages too, with the same imaging caveat.
  5. A large persisted inventory XML here would be the real ground truth. Dell
     documents none, so expect only settings and catalog files.
  6. A row like "Intel(R) Management Engine Components" with a DisplayVersion in
     the same scheme as the DCU card (e.g. 2413.x) funds a <packages> section in
     the scan enrichment, which is the strongest baseline for package updates.
'@
