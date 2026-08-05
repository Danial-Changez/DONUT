using module ".\ElevationContext.psm1"

<#
.SYNOPSIS
    Resolves DONUT's per-machine data root and its config/logs/reports folders.

.DESCRIPTION
    Everything user-scoped used to hang off %LOCALAPPDATA%, which is per-account.
    Once the UI can run de-elevated as the console user while privileged work runs
    as an admin account, that splits into two stores: two config.json files, two
    GitHub tokens, two log folders. This resolves one machine-wide root instead,
    so both modes read and write the same data.

.NOTES
    Secure() is best-effort and needs elevation - a de-elevated process cannot
    Set-Acl under ProgramData. The first elevated launch establishes the ACL that
    lets the de-elevated one write at all: ProgramData's inherited ACL lets any
    local user create files but not modify another account's, so without the
    explicit grant a de-elevated run cannot overwrite what an elevated run wrote.
#>
class DonutPaths {

    # Machine-wide, deliberately not %LOCALAPPDATA%: see .DESCRIPTION.
    static [string] DataRoot() {
        return (Join-Path $env:ProgramData 'DONUT\data')
    }

    static [string] ConfigDir() { return (Join-Path ([DonutPaths]::DataRoot()) 'config') }
    static [string] LogsDir() { return (Join-Path ([DonutPaths]::DataRoot()) 'logs') }
    static [string] ReportsDir() { return (Join-Path ([DonutPaths]::DataRoot()) 'reports') }

    # Where DONUT's data lived before the shared root, so a caller can say so when the new
    # root is empty. Nothing reads or writes this path. The move is done by hand.
    static [string] LegacyRoot() {
        if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { return $null }
        return (Join-Path $env:LOCALAPPDATA 'DONUT')
    }

    # Strips the inherited ACL down to SYSTEM / Administrators / the interactive user,
    # mirroring PersonLensService's exchange folder. Returns '' or a reason fragment.
    static [string] Secure([string]$dir) {
        $who = $null
        try {
            $who = [ElevationContext]::InteractiveUser()
            if (-not $who) { return 'no interactive desktop session to grant access to' }
            $acl = Get-Acl $dir
            $acl.SetAccessRuleProtection($true, $false)
            $system = [System.Security.Principal.SecurityIdentifier]::new(
                [System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
            $admins = [System.Security.Principal.SecurityIdentifier]::new(
                [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
            foreach ($principal in @($system, $admins, $who)) {
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                        $principal, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
            Set-Acl -Path $dir -AclObject $acl
            return ''
        }
        catch {
            return "could not secure ${dir} for ${who}: $($_.Exception.Message)"
        }
    }
}
