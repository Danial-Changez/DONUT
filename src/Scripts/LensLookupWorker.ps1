#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool wrapper that runs a Lens lookup (or warms the agent) and emits JSON.

.DESCRIPTION
    Invoked on the runspace pool by FinderPresenter (like AdSearchWorker.ps1). Constructs
    PersonLensService and returns its raw JSON bundle so the result crosses the runspace
    boundary without class-identity coupling; the UI parses it with PersonLens.FromJson.
    The persistent de-elevated agent (and the request/response exchange) lives in
    PersonLensService.

    -WarmOnly: called once at app startup to start the de-elevated LensAgent (which then
    pre-warms its libraries in parallel with DONUT's own startup) without running a
    lookup. Returns '' on success or the agent's failure reason.

    -StopAgent: called once at app close to run the full parent-side teardown
    (StopAndPurgeAgent) without running a lookup. Kept on the pool so the UI never has to
    parse-load PersonLensService itself - the teardown + its literals stay single-sourced
    in the service, invoked here in the worker runspace where the service already loads.

.PARAMETER Identity
    UPN / DOMAIN\SAM / bare SAM / display name to resolve (ignored with -WarmOnly).

.PARAMETER SiteServer
    SCCM AdminService host.

.PARAMETER SourceRoot
    DONUT 'src' root, used to locate Scripts\LensAgent.ps1.

.PARAMETER OwnerOf
    Machine names: return their SCCM primary users instead of running a person lookup.
    The whole list travels in one request; the agent resolves them back to back.

.PARAMETER SoftwareFor
    Identity: return their SCCM application deployments instead of running a person
    lookup. Dispatched beside the person lookup, and it rides the same -Sam hint.

.PARAMETER Sam
    Optional sAMAccountName hint from the finder row, so the agent can start SCCM
    affinity before the AD user read resolves it.

.PARAMETER Dn
    Optional distinguishedName from the finder row. The agent binds it directly,
    which pins the exact picked account and works across sibling forests.

.PARAMETER Domains
    The finder's configured domain list. Device AD reads fall back to these when
    the agent forest's GC does not hold a computer object.

.PARAMETER TimeoutSec
    Max seconds to wait for a lookup result. Default 60.

.PARAMETER WarmOnly
    Start/verify the agent and return, without running a lookup.

.PARAMETER StopAgent
    Stop/unregister the agent and purge every Lens exchange dir, without running a lookup.

.NOTES
    Runs on a pool runspace, as the elevated admin account.
#>
using module "..\Services\PersonLensService.psm1"
using module "..\Core\ElevationContext.psm1"

param(
    [string] $Identity = '',
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $SourceRoot,
    [string] $Sam = '',
    [string] $Dn = '',
    [string[]] $Domains = @(),
    [string[]] $OwnerOf = @(),
    [string] $SoftwareFor = '',
    [int] $TimeoutSec = 60,
    [switch] $WarmOnly,
    [switch] $StopAgent
)

$ErrorActionPreference = 'Stop'

# The parent subtracts this from its dispatch time to see pool queueing, not work.
Write-Information -MessageData ([datetime]::UtcNow.ToString('o')) -Tags 'WorkerStart'

# Runs de-elevated too, so an agent left by an earlier elevated session is still swept.
if ($StopAgent) { [PersonLensService]::StopAndPurgeAgent(); return }

$svc = [PersonLensService]::new($SiteServer, $SourceRoot)
$svc.TimeoutSec = $TimeoutSec
$svc.SamHint = $Sam
$svc.DnHint = $Dn
$svc.SearchDomains = @($Domains)
if ($WarmOnly) {
    # There is no agent to warm when DONUT is already the interactive user.
    if (-not [ElevationContext]::IsElevated()) { return '' }
    return $svc.EnsureAgent()
}
# Owner lookups ride the same agent and RBAC scope, so they are a mode, not a worker.
if (@($OwnerOf).Count -gt 0) { return $svc.RunOwnerLookupJson($OwnerOf) }
# Software lookups too, dispatched beside the person lookup they never wait on.
if ($SoftwareFor) { return $svc.RunSoftwareLookupJson($SoftwareFor) }
$svc.RunLookupJson($Identity)
