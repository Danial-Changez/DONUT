#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool wrapper for the Lens lookup, the finder AD search, or an agent
    warm/teardown - a thin relay to the persistent agent that emits JSON.

.DESCRIPTION
    Invoked on the runspace pool by the presenters. Constructs PersonLensService and
    returns its raw JSON so the result crosses the runspace boundary without
    class-identity coupling (a lookup bundle the UI parses with PersonLens.FromJson, or
    the finder's { rows: [...] } search bundle). The persistent de-elevated agent (and
    the request/response exchange) lives in PersonLensService.

    -WarmOnly: called once at app startup to start the de-elevated LensAgent (which then
    pre-warms its libraries in parallel with DONUT's own startup) WITHOUT running a
    lookup. Returns '' on success or the agent's failure reason.

    -StopAgent: called once at app close to run the full parent-side teardown
    (StopAndPurgeAgent) WITHOUT running a lookup. Kept on the pool so the UI never has to
    parse-load PersonLensService itself - the teardown + its literals stay single-sourced
    in the service, invoked here in the worker runspace where the service already loads.

.PARAMETER Identity
    UPN / DOMAIN\SAM / bare SAM / display name to resolve (ignored with -WarmOnly).

.PARAMETER SiteServer
    SCCM AdminService host.

.PARAMETER SourceRoot
    DONUT 'src' root, used to locate Scripts\LensAgent.ps1.

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

param(
    [string] $Identity = '',
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $SourceRoot,
    [string] $Sam = '',
    [int] $TimeoutSec = 60,
    [switch] $WarmOnly,
    [switch] $StopAgent,
    [switch] $Search,
    [string] $Prefix = '',
    [string[]] $Domains = @()
)

$ErrorActionPreference = 'Stop'

# Teardown needs no live service (StopAndPurgeAgent is static): run it and return before
# constructing anything, so app close never depends on an agent/SCCM round-trip.
if ($StopAgent) { [PersonLensService]::StopAndPurgeAgent(); return }

$svc = [PersonLensService]::new($SiteServer, $SourceRoot)
$svc.TimeoutSec = $TimeoutSec
$svc.SamHint = $Sam
if ($WarmOnly) { return $svc.EnsureAgent() }
# -Search: run the finder's multi-forest AD search over the warm agent (emits { rows: [...] }).
if ($Search) { return $svc.RunSearchJson($Prefix, $Domains) }
$svc.RunLookupJson($Identity)
