# Handoff: diagram truth-up + integration coverage (2026-08-01)

Continuation brief for an agent with a Windows checkout of this repo. A Linux-side
session completed the items under "Done"; everything under "Remaining" is verified,
scoped work with evidence already gathered. Delete this file in the final commit of
the work it describes.

## Contents

- [Repo rules](#repo-rules)
- [Done and pushed](#done-and-pushed)
- [Verified routing facts](#verified-routing-facts)
- [Remaining 1: diagram fix lists](#remaining-1-diagram-fix-lists)
- [Remaining 2: integration test follow-ups](#remaining-2-integration-test-follow-ups)
- [Windows verification checklist](#windows-verification-checklist)
- [Deferred backlog](#deferred-backlog)

## Repo rules

- Commit to `main`, push to origin. No `Co-Authored-By` or session trailers.
- Update `docs/` in the same change as code. Doc style: bullets over prose, no em
  dashes in docs prose, command + expected-output examples.
- Full suite before any push: `.\tools\Invoke-Tests.ps1` from a FRESH terminal
  (`using module` never reloads; the runner self-relaunches if the session is
  poisoned, but start clean anyway). Compare failing-test NAME sets, not counts.
- Style hook caps comments at 2 lines in `src/`; a Pester hook runs per edited
  logic module.
- Suite pins Pester 6 (floor 6.0.1) via `tools/Import-PinnedPester.ps1`.

## Done and pushed

| Commit | What |
| :--- | :--- |
| `2e6faec` | Coverage via built-in JaCoCo + ReportGenerator; shared Pester pin |
| `23f67d8` | Pester 6 migration (suite + runner + hook + docs) |
| `1af39f6` | PendingIntent JSON round-trip fix (TZ-shifted stamps off UTC) |
| `c9053d5` | Runner relaunches into a clean child pwsh when repo classes are stale |
| `7d9381a` | Unit tests: Lens exchange, SystemInfoService.Gather, DiskUsageService; `TimeFormat::NormalizeStamp` fixes the stamp mangle in 3 more models |
| `8d6e642` | Coverage script moved to `tools/`, `-Format JaCoCo\|Cobertura` toggle |
| this handoff's commits | 3 new integration test files (worker ArgsFile protocol, elevation intent handover, config/recents persistence); `%ProgramData%` redirect fix in `Core.Integration.Tests.ps1` + `ConfigManager.Tests.ps1` (un-broke 16 Linux failures that were null-data-root artifacts); `elevation_sequence_diagram.puml` (new) embedded in `elevation.md`; `testing.md` integration section now describes reality |

Linux suite state at handoff: total 831, passed 783, failed 43 (all Windows-only
environment failures), skipped 5. Windows expectation: all green.

## Verified routing facts

Confirmed against source with file:line during the audit. Use these to judge any
diagram statement; each was verified, not guessed.

1. `AsyncJob` never runs `RemoteWorker.ps1` on a pool runspace. The pool runs only
   the class-free `WorkerProcess::Launcher` scriptblock, which `Process.Start`s a
   child pwsh with `-ArgsFile/-ResultFile` temp JSON (`WorkerProcess.psm1:40-88`).
2. Two pools: worker (`RunspaceManager::GetPool`) and interactive
   (`GetInteractivePool`, fixed size 4). All `PoolScriptJob` work (AD search, Lens,
   unlock/reset, startup task) rides the interactive pool.
3. The fast-resolve lane (`ResolveProcessJob` -> `ResolveWorker.ps1`) is a direct
   child process: no pool, no launcher, no ArgsFile.
4. Inventory tries a DCOM CIM session first (`WorkerServices.psm1:378-396`); the
   psexec probe is only the fallback.
5. De-elevated Lens lookups have no agent, no task, no crypto, no partials: they
   dot-source `LensAgent.Common.ps1` in-process (`PersonLensService.psm1:240-248`).
6. Only four actions are elevation-gated: RunAll, DiskScan, DeleteFolders,
   StartupTask. Single-host Run and Inventory are not.
7. `PendingIntentStore.Take` deletes before validating (fires at most once); the
   resume runs on a 3 s dispatcher timer, not synchronously at boot.
8. Self-update hands off to `powershell.exe` 5.1 running a staged COPY of
   `InstallWorker.ps1` (the MSI replaces the source tree mid-install).
9. `WarmPool` runs `RemoteWorker.ps1` IN the pool runspace via
   `AddCommand + AddParameter` (deliberate: it loads the worker class graph).
10. `ReportsPath` is machine-wide: `%ProgramData%\DONUT\data\reports`.
11. Recents/inventory/disk-usage/owner all persist into `config.json` via
    `RecentConnectionsStore -> ConfigManager.SaveConfig`, coalesced by `DeferSave`.

## Remaining 1: diagram fix lists

`docs/diagrams/*.puml`, rendered by `tools/Render-Diagrams.ps1` (needs java +
graphviz; jar auto-downloads to `tools/.cache/`). CI renders on the docs build, so
a bad edit breaks the site: render locally before pushing.

Conventions: no `!theme`/`!include` (dark theme injected at render); `@startuml
<name>` must equal filename; class diagrams omit cross-subsystem arrows (those live
in `component_diagram.puml`); member notation `+/-/#`, `+{static}`,
`Name(args): Type`; never add `ParticipantPadding`/`BoxPadding` skinparams
(deprecation banner). Verify every member you add against src before drawing it.

- `class_lens.puml`: remove `MachineNameMatcher` (class deleted from src; also
  purge its row in `docs/development/architecture/key-classes.md:26`). Add
  `AdSearchRank` (`AdSearchResult.psm1:62`). Expand `PersonLensService` with the
  agent surface: `EnsureAgent`, `RunOwnerLookupJson`, `StopAndPurgeAgent`,
  `SweepStaleExchanges`, `AgentDir`, `$AgentTaskName`, crypto statics.
- `class_ui.puml`: `HostViewModel.StatusCategory` does not exist, real field is
  `SortStatusRank` (`HostViewModel.psm1:55`). Add: MainPresenter `Watchdog`,
  `IntentStore`, `RestartElevated/EnsureElevated/SpawnElevated/ResumePendingIntent`;
  FinderPresenter `OwnerJob/ResolveOwners/ReapOwners`; HostViewModel
  `OwnerName/OwnerTip/SetOwner/IdentityState/UpdatesIdentityText/RemoveCommand`;
  InventoryPresenter `DeleteSelectedFolders/CompleteDeleteFolders/ResumeDiskScan`;
  ResolutionCoordinator fast lane
  (`StartFastResolve/StartClassicResolve/StartNextFastResolve/OnFastResolveFault`);
  LensDeviceViewModel + PersonLensViewModel missing members. Move
  SystemInfo/SystemInfoService into a Services package (they live in
  `src/Services/SystemInfoService.psm1`).
- `class_config.puml`: `StartupTaskService.TaskName()` -> `TaskNameFor(user)`
  (`:60`), add `ResolveOwner`. ADD `ElevationRelaunch` (`BuildSpec/Spawn`) and
  `PendingIntentStore` (`Save/Take/Discard/IntentPath` + arrows to `PendingIntent`
  and `LogService`); this diagram is the one embedded on `elevation.md`, which
  currently shows none of its subject classes. Add
  `ElevationContext.InteractiveUser`; RecentConnectionsStore
  `UpsertOwner/GetByHost/FlushSave/Count`; `RecentConnection.Owner`; LogService
  `LogDebug/LogStructured/GetRecentLogs`.
- `class_remote_exec.puml`: remove `DiskUsageService +{static} TopN` (not a
  static). Add `PrepareDeleteFolders`; ExecutionService
  `RunDeleteFoldersPhase/BuildDeleteCommand/WarmRuntimeAssemblies/`
  `WarmScanLaunchPath/GatherRemoteInventory/DeployWizTree`; fix `TailAndScanLog`
  to `+` (public). `RemoteJobService::Fail` is hidden -> `-{static}`. Add the
  missing `RemoteError.psm1` exceptions (HostOffline/HostUnresolvable/
  RpcUnavailable/RemoteExecution/RemoteProcessStart/DcuNotInstalled + ErrorLevel
  and RemoteFailureReason enums; read the file for the real base classes).
  HostResolver: add `SetActiveDc/HasActiveDc/GetActiveDc` and
  `CacheName/GetVerifiedName/ClearVerifiedName`.
- `class_runspaces.puml`: DELETE the wrong `WorkerProcess ..> RunspaceManager`
  arrow (zero references in source; `AsyncJob ..> RunspaceManager` is the real
  edge and already drawn). Add `WorkerProcess.FindPwsh`, AsyncJob
  `FailureMessage/StartedAtUtc/LogStallHeartbeat/HealThreadPoolIfStarved`,
  `ResolveProcessJob.KillChild`, and `PoolScriptJob ..> RunspaceManager :
  interactive pool`.
- `component_diagram.puml`: Core package lists ~7 of 16 modules; add the missing
  (DispatcherWatchdog, PoolScriptJob, ResolveProcessJob, DonutPaths,
  ElevationContext, ElevationRelaunch, TimeFormat, ViewLoader, BuildProvenance).
  Add PendingIntentStore (Services), ResetPasswordViewModel (ViewModels),
  LensAgent.Common.ps1 (Scripts). Add arrows: `MainPresenter ..>
  PendingIntentStore / ElevationRelaunch / DispatcherWatchdog`. Label the
  FinderPresenter -> LensLookupWorker arrow to cover the `-OwnerOf` batch. Update
  the Views listing for the Home/Settings sub-view split.
- `scan_sequence_diagram.puml`: `Presenter -> Pool: GetPool()` is wrong; pool
  acquisition happens inside `AsyncJob.Start`.
- `activity_diagram.puml`: the JobType switch is missing the DeleteFolders branch
  (`RunDeleteFoldersPhase`). Also fix the stale "pool runspace" description at
  `docs/diagrams/README.md:38` and the heading at
  `docs/development/architecture/runtime-flows.md:22` (worker runs in an isolated
  child pwsh).
- `inventory_sequence_diagram.puml`: re-attribute lifelines after the presenter
  split (SelectHost/InventoryIsStale/CompleteInventory/CompleteDiskScan/
  PopulateDetailCards belong to InventoryPresenter; CompleteResolve to
  ResolutionCoordinator). Add the DeleteFolders leg + its elevation gate. Reflect
  that inventory tries CIM first, psexec only as fallback.
- `ad_finder_sequence_diagram.puml`: mention `AdSearchRank::Order` ranking; add
  the machine-owner batch group (routing fact 11 + `FinderPresenter:393/414`).
- `lens_lookup_sequence_diagram.puml`: add the `-OwnerOf` request kind (answered
  inline on the serve loop, no partials, `LensAgent.ps1:157-159`) and `-StopAgent`
  as a worker mode; fix `src/Scripts/LensLookupWorker.ps1`'s docstring ("invoked
  by HomePresenter" -> FinderPresenter).
- `applyUpdates_sequence_diagram.puml`: add a compact de-elevated opening branch
  (EnsureElevated -> pending intent -> UAC relaunch -> resume re-enters the flow).
- `update_sequence_diagram.puml` + README mermaid twin: align the msiexec flags
  with `InstallWorker.ps1` (puml says `/passive`, mermaid says `/qb!`; read the
  script and make both match reality).
- `network-flow.puml`: accurate; no changes required.

Done already: `elevation_sequence_diagram.puml` created, embedded in
`elevation.md`, indexed in the README table, renders clean.

## Remaining 2: integration test follow-ups

Landed this session (first Windows pass still needed):
`WorkerProtocol.Integration.Tests.ps1` (real `RemoteWorker.ps1` through the real
ArgsFile/ResultFile transport, success + failure verdicts),
`ElevationIntent.Integration.Tests.ps1` (real store on a redirected data root,
cross-process claim by a child pwsh), `ConfigPersistence.Integration.Tests.ps1`
(recents/owner survive a restart; corrupt config falls back).

Still open, in value order:

1. LensAgent real-process test. Nothing ever starts the real `LensAgent.ps1`
   (`LensAgent.Common.ps1`, 503 lines, has zero runtime tests). Design: temp
   exchange dir + write `key.bin` (48 bytes via `PersonLensService::NewKeyIv`),
   start `pwsh -File src\Scripts\LensAgent.ps1 -ExchangeDir <dir> -ParentPid $PID
   -SiteServer site.invalid`; wait for `heartbeat.txt` (<= 10 s); drive
   `ExchangeRoundTrip` through a subclass stubbing only `EnsureAgent` (pattern in
   `tests/Unit/PersonLensService.Tests.ps1`) with `$env:ProgramData` pointed at
   the parent of the exchange dir; expect an encrypted result (an errors bundle is
   fine off-domain: assert `PersonLens::FromJson` parses it); then `stop.flag`
   and assert the process exits <= 5 s. Probably `-Skip:(-not $IsWindows)`:
   verify whether the agent survives dot-sourcing its AD/SCCM helpers off
   Windows before ungating.
2. `RemoteWorker.Integration.Tests.ps1` drives the legacy named-parameter entry
   and asserts only exit 1 + one log line. Now that WorkerProtocol covers the real
   transport, either retire it or tighten its assertion (it passes even if the
   worker breaks one call after logging).
3. `StartupResolveSmoke.Tests.ps1` submission 3 (DC warm) uses the in-pool path
   while production DC warm uses the child-process path; WorkerProtocol's Warm
   test now covers the production transport, so no action needed, but keep the
   note if editing that file.
4. Deeper remote legs (psexec, dcu-cli, SMB copy-back, WizTree deploy) are
   lab-only by design: `tools/Invoke-DiagnosticRun.ps1` on the user's schedule.
   Do not wire them into the suite.

## Windows verification checklist

```powershell
git pull                                   # must include the handoff commits
# fresh terminal, then:
.\tools\Invoke-Tests.ps1                   # expect: all passed, 5 skipped
.\tools\Generate-CoverageReport.ps1        # renders CoverageReport\index.html
```

- The three new Integration files get their first real-Windows execution here;
  `WorkerProtocol` asserts both verdict shapes on a domain-joined box too
  (Warm completes with a real DC; the unresolvable host still fails cleanly).
- `Core.Integration.Tests.ps1` + `ConfigManager.Tests.ps1` no longer write to the
  operator's real `%ProgramData%\DONUT\data\config.json`. If your real config was
  previously clobbered with `activeCommand=applyUpdates, throttleLimit=10`, that
  was these tests; re-check your settings once.
- Diagram edits: render with `.\tools\Render-Diagrams.ps1` and eyeball the SVGs
  before pushing (CI docs build consumes them).

## Deferred backlog (unchanged)

- Windows-only test tagging + `Filter.ExcludeTag` so Linux runs go green.
- `Run.Parallel` experiment (needs unique temp dirs + the known using-module
  compile-deadlock care).
- `ElevationRelaunch.Tests.ps1:36` discovery-time `-Skip` bug (test is always skipped);
  fix with the `BeforeDiscovery` pattern from `BuildProvenance.Tests.ps1`.
- `CodeCoverage.CoveragePercentTarget` policy decision (Pester 6 default 75%
  prints red at ~70%).
- `TestResult` XML export if CI ever grows a report step.
