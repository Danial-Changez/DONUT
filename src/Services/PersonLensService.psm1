using module "..\Core\LogService.psm1"
using module "..\Models\PersonLens.psm1"

<#
.SYNOPSIS
    Resolves a person to a PersonLens (directory facts + SCCM devices + BitLocker),
    running the lookup de-elevated as the interactive user.

.DESCRIPTION
    DONUT runs elevated as the admin account, but the Lens data (SCCM affinity +
    BitLocker) is readable only by the operator's regular account. Lookup() runs
    LensWorker.ps1 DE-ELEVATED as the logged-on user via a one-shot scheduled task
    (RunLookupJson - the env-coupled seam, the cross-account de-elevation proven in
    tools/Test-DeElevatedSccm.ps1) and parses its JSON bundle into a typed PersonLens.
    The child's result lands in a ProgramData exchange folder whose inherited ACL is
    stripped down to SYSTEM / Administrators / the interactive user (the admin's own
    %TEMP% is unreachable to that account); the only elevated action is registering
    the task. Because the bundle holds BitLocker recovery keys, every payload is
    AES-256 encrypted with a per-lookup key (key.bin in the exchange dir) and the dir
    is deleted per lookup, swept for stale leftovers, and purged on window close.
    The child also writes an early PARTIAL bundle (directory facts only), which
    RunLookupJson streams to the caller on the Information stream (tag 'LensPartial')
    so the UI can render the person while the SCCM/BitLocker crawl finishes.

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

    # --- exchange crypto + hygiene (pure; format shared with LensWorker.ps1) --------

    # 48 random bytes per lookup: 32-byte AES-256 key + 16-byte IV.
    static [byte[]] NewKeyIv() {
        $b = [byte[]]::new(48)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($b) } finally { $rng.Dispose() }
        return $b
    }

    # AES-256-CBC (PKCS7) over the UTF-8 text - the encrypt twin of LensWorker's
    # Write-LensBundle; kept here so the round-trip is unit-testable.
    static [byte[]] ProtectText([string]$text, [byte[]]$keyIv) {
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = [byte[]]($keyIv[0..31]); $aes.IV = [byte[]]($keyIv[32..47])
            $enc = $aes.CreateEncryptor()
            $plain = [System.Text.Encoding]::UTF8.GetBytes($text)
            return $enc.TransformFinalBlock($plain, 0, $plain.Length)
        }
        finally { $aes.Dispose() }
    }

    static [string] UnprotectText([byte[]]$blob, [byte[]]$keyIv) {
        $aes = [System.Security.Cryptography.Aes]::Create()
        try {
            $aes.Key = [byte[]]($keyIv[0..31]); $aes.IV = [byte[]]($keyIv[32..47])
            $dec = $aes.CreateDecryptor()
            return [System.Text.Encoding]::UTF8.GetString($dec.TransformFinalBlock($blob, 0, $blob.Length))
        }
        finally { $aes.Dispose() }
    }

    # Deletes lens-* exchange dirs older than $minutes - crash leftovers that may hold
    # (encrypted) BitLocker bundles. HomePresenter's Closing sweep removes ALL on exit.
    static [void] SweepStaleExchanges([int]$minutes) {
        $root = Join-Path $env:ProgramData 'DONUT'
        Get-ChildItem -Path $root -Directory -Filter 'lens-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddMinutes(-$minutes) } |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
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

        # Sweep leftovers a crashed run may have abandoned (any live lookup's dir is
        # younger than this window).
        [PersonLensService]::SweepStaleExchanges(15)

        $dir = Join-Path $env:ProgramData ("DONUT\lens-" + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $resultPath = Join-Path $dir 'result.bin'
        $partialPath = Join-Path $dir 'partial.bin'
        $taskName = $null
        try {
            # Strip the inherited ACL (ProgramData grants all local users read!) down to
            # SYSTEM / Administrators / the interactive user - the bundle holds BitLocker keys.
            try {
                $acl = Get-Acl $dir
                $acl.SetAccessRuleProtection($true, $false)
                $system = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
                $admins = [System.Security.Principal.SecurityIdentifier]::new([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($system, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($admins, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($interactiveUser, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
                Set-Acl -Path $dir -AclObject $acl
            }
            catch {
                return [PersonLensService]::ErrorBundle("Could not secure the exchange folder for ${interactiveUser}: $($_.Exception.Message)")
            }

            # Per-lookup AES key: the child encrypts every payload with it, so BitLocker
            # keys never touch the disk in the clear.
            $keyIv = [PersonLensService]::NewKeyIv()
            [IO.File]::WriteAllBytes((Join-Path $dir 'key.bin'), $keyIv)

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

            # 100ms poll; the child's writes are atomic (tmp + rename), so no settle wait.
            # When the partial (directory facts) lands, stream it to the presenter on the
            # Information stream - the same channel the DCU workers use for live output.
            $deadline = (Get-Date).AddSeconds($this.TimeoutSec)
            $partialSent = $false
            while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $resultPath)) {
                if (-not $partialSent -and (Test-Path -LiteralPath $partialPath)) {
                    $partialSent = $true
                    try {
                        Write-Information -MessageData ([PersonLensService]::UnprotectText([IO.File]::ReadAllBytes($partialPath), $keyIv)) -Tags 'LensPartial'
                    }
                    catch { }
                }
                Start-Sleep -Milliseconds 100
            }
            if (-not (Test-Path -LiteralPath $resultPath)) {
                return [PersonLensService]::ErrorBundle("The lens lookup did not complete within $($this.TimeoutSec)s (the de-elevated child may have failed to start as $interactiveUser).")
            }
            return [PersonLensService]::UnprotectText([IO.File]::ReadAllBytes($resultPath), $keyIv)
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
