#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool wrapper that runs a Lens lookup (or warms the agent) and emits JSON.

.DESCRIPTION
    Invoked on the runspace pool by HomePresenter (like AdSearchWorker.ps1). Constructs
    PersonLensService and returns its raw JSON bundle so the result crosses the runspace
    boundary without class-identity coupling; the UI parses it with PersonLens.FromJson.
    The persistent de-elevated agent (and the request/response exchange) lives in
    PersonLensService.

    -WarmOnly: called once at app startup to start the de-elevated LensAgent (which then
    pre-warms its libraries in parallel with DONUT's own startup) WITHOUT running a
    lookup. Returns '' on success or the agent's failure reason.

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
    [switch] $WarmOnly
)

$ErrorActionPreference = 'Stop'

$svc = [PersonLensService]::new($SiteServer, $SourceRoot)
$svc.TimeoutSec = $TimeoutSec
$svc.SamHint = $Sam
if ($WarmOnly) { return $svc.EnsureAgent() }
$svc.RunLookupJson($Identity)
