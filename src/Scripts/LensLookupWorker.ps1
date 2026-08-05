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

.PARAMETER Sam
    Optional sAMAccountName hint from the finder row, so the agent can start SCCM
    affinity before the AD user read resolves it.

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
    [string[]] $OwnerOf = @(),
    [int] $TimeoutSec = 60,
    [switch] $WarmOnly,
    [switch] $StopAgent
)

$ErrorActionPreference = 'Stop'

# Runs de-elevated too, so an agent left by an earlier elevated session is still swept.
if ($StopAgent) { [PersonLensService]::StopAndPurgeAgent(); return }

$svc = [PersonLensService]::new($SiteServer, $SourceRoot)
$svc.TimeoutSec = $TimeoutSec
$svc.SamHint = $Sam
if ($WarmOnly) {
    # There is no agent to warm when DONUT is already the interactive user.
    if (-not [ElevationContext]::IsElevated()) { return '' }
    return $svc.EnsureAgent()
}
# Owner lookups ride the same agent and RBAC scope, so they are a mode, not a worker.
if (@($OwnerOf).Count -gt 0) { return $svc.RunOwnerLookupJson($OwnerOf) }
$svc.RunLookupJson($Identity)
