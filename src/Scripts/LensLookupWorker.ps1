#Requires -Version 5.1
<#
.SYNOPSIS
    Runspace-pool wrapper that runs the Lens lookup and emits the JSON bundle.

.DESCRIPTION
    Invoked on the runspace pool by HomePresenter (like AdSearchWorker.ps1). Constructs
    PersonLensService and returns its raw JSON bundle so the result crosses the runspace
    boundary without class-identity coupling; the UI parses it with PersonLens.FromJson.
    The de-elevation to the interactive user lives in PersonLensService.RunLookupJson.

.PARAMETER Identity
    UPN / DOMAIN\SAM / bare SAM / display name to resolve.

.PARAMETER SiteServer
    SCCM AdminService host.

.PARAMETER SourceRoot
    DONUT 'src' root, used to locate Scripts\LensWorker.ps1.

.PARAMETER TimeoutSec
    Max seconds to wait for the de-elevated child. Default 60.

.NOTES
    Runs on a pool runspace, as the elevated admin account.
#>
using module "..\Services\PersonLensService.psm1"

param(
    [Parameter(Mandatory)] [string] $Identity,
    [Parameter(Mandatory)] [string] $SiteServer,
    [Parameter(Mandatory)] [string] $SourceRoot,
    [int] $TimeoutSec = 60
)

$ErrorActionPreference = 'Stop'

$svc = [PersonLensService]::new($SiteServer, $SourceRoot)
$svc.TimeoutSec = $TimeoutSec
$svc.RunLookupJson($Identity)
