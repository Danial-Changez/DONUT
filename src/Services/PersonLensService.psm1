using module "..\Core\LogService.psm1"
using module "..\Models\PersonLens.psm1"

<#
.SYNOPSIS
    Resolves a person to a PersonLens (directory facts + SCCM devices + BitLocker),
    running the lookup de-elevated as the interactive user.

.DESCRIPTION
    DONUT runs elevated as the admin account, but the Lens data (SCCM affinity/model +
    BitLocker) is readable only by the operator's regular account. Lookup() runs
    LensWorker.ps1 DE-ELEVATED as the logged-on user via a one-shot scheduled task
    (RunLookupJson - the env-coupled seam, the cross-account de-elevation proven in
    tools/Test-DeElevatedSccm.ps1) and parses its JSON bundle into a typed PersonLens.
    The child's result lands in a ProgramData exchange folder ACL'd to the interactive
    user (the admin's own %TEMP% is unreachable to that account); the only elevated
    action is registering the task.

.NOTES
    Mirrors ActiveDirectoryService's seam pattern: the directory/task I/O is isolated in
    the overridable RunLookupJson seam so the parse wiring is unit-testable off a domain
    by subclassing and faking it. LensLookupWorker.ps1 is the pool wrapper that calls this.
#>
class PersonLensService {
    [LogService] $Logger
    [string]     $SiteServer
    [string]     $SourceRoot
    [int]        $TimeoutSec = 60

    PersonLensService([string]$siteServer, [string]$sourceRoot) {
        $this.SiteServer = $siteServer
        $this.SourceRoot = $sourceRoot
        $this.Logger = [NullLogService]::new()
    }

    PersonLensService([string]$siteServer, [string]$sourceRoot, [LogService]$logger) {
        $this.SiteServer = $siteServer
        $this.SourceRoot = $sourceRoot
        $this.Logger = [LogService]::Coalesce($logger)
    }

    # Resolves a person to a typed PersonLens. Testable by faking RunLookupJson.
    [PersonLens] Lookup([string]$identity) {
        return [PersonLens]::FromJson($this.RunLookupJson($identity))
    }

    # A parseable error bundle so the UI shows a reason instead of hanging.
    hidden static [string] ErrorBundle([string]$message) {
        return (@{ errors = @($message) } | ConvertTo-Json -Compress)
    }

    # --- env-coupled seam (overridden in tests) ---------------------------------

    # Runs LensWorker.ps1 DE-ELEVATED via a one-shot scheduled task (Interactive logon =
    # the logged-on token, RunLevel Limited) and returns the raw JSON bundle; see .DESCRIPTION.
    [string] RunLookupJson([string]$identity) {
        $lensWorker = Join-Path $this.SourceRoot 'Scripts\LensWorker.ps1'
        if (-not (Test-Path -LiteralPath $lensWorker)) {
            return [PersonLensService]::ErrorBundle("LensWorker.ps1 not found at $lensWorker")
        }

        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $explorer) {
            return [PersonLensService]::ErrorBundle('No interactive desktop session to de-elevate into.')
        }
        $owner = Invoke-CimMethod -InputObject $explorer -MethodName GetOwner
        $interactiveUser = "$($owner.Domain)\$($owner.User)"

        $dir = Join-Path $env:ProgramData ("DONUT\lens-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $resultPath = Join-Path $dir 'result.json'
        $taskName = $null
        try {
            try {
                $acl = Get-Acl $dir
                $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($interactiveUser, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
                $acl.AddAccessRule($rule)
                Set-Acl -Path $dir -AclObject $acl
            }
            catch {
                return [PersonLensService]::ErrorBundle("Could not grant $interactiveUser on the exchange folder: $($_.Exception.Message)")
            }

            # Resolve pwsh.exe via PATH: $PID isn't accessible in a class method, and the
            # production host is Donut.Launcher.exe anyway. PowerShell 7 is a prerequisite.
            $cmd = Get-Command pwsh -ErrorAction SilentlyContinue
            $pwshPath = if ($cmd) { [string]$cmd.Source } else { '' }
            if (-not $pwshPath) { return [PersonLensService]::ErrorBundle('Could not resolve pwsh.exe to run the de-elevated child.') }

            $taskName = 'DONUT-Lens-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
            $argline = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Identity "{1}" -SiteServer "{2}" -ResultPath "{3}"' -f $lensWorker, $identity, $this.SiteServer, $resultPath
            $action = New-ScheduledTaskAction -Execute $pwshPath -Argument $argline
            $principal = New-ScheduledTaskPrincipal -UserId $interactiveUser -LogonType Interactive -RunLevel Limited
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
            $task = New-ScheduledTask -Action $action -Principal $principal -Settings $settings
            Register-ScheduledTask -TaskName $taskName -InputObject $task -Force -ErrorAction Stop | Out-Null
            Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

            $deadline = (Get-Date).AddSeconds($this.TimeoutSec)
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
                Start-Sleep -Milliseconds 400
            }
            if (-not (Test-Path -LiteralPath $resultPath)) {
                return [PersonLensService]::ErrorBundle("The lens lookup did not complete within $($this.TimeoutSec)s (the de-elevated child may have failed to start as $interactiveUser).")
            }
            Start-Sleep -Milliseconds 200   # let the write settle
            return (Get-Content -LiteralPath $resultPath -Raw)
        }
        catch {
            return [PersonLensService]::ErrorBundle("Lens lookup failed: $($_.Exception.Message)")
        }
        finally {
            if ($taskName) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
