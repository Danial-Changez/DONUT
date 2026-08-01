---
title: Key classes
description: The Models / Core / Services / ViewModels / Presenters reference tables, with the full class and component diagrams.
---

Many models are deliberately WPF-free **pure mappers/DTOs** (no UI, no I/O) so the
decision/format logic is unit-tested off-domain; a view-model (or coordinator)
consumes the result and exposes it to the bindings.

## Models (`src/Models/`)

| Class | Purpose |
|-------|---------|
| `AppConfig` | Configuration container with defaults, settings merge, and DCU CLI argument building |
| `DeviceContext` | Remote device state: hostname, IP, online status, status message |
| `JobStatus` / `JobKind` (enums, `JobEnums.psm1`) | Job lifecycle state and the kind of remote operation (`Scan`, `UpdateScan`, `UpdateApply`, `Inventory`, `DiskScan`, `DeleteFolders`, `Resolve`) |
| `LogLine` (+ `LogSeverity`) | One typed terminal line: severity + normalized `HH:mm:ss` stamp + text, with the `[Error]`/`[Warn]` tag precomputed for the log ListBox binding |
| `FleetCardStatus` | Pure mapper: a job's (type, status, reboot) → card label, colour key, busy flag |
| `DcuProgress` | Pure parser: a DCU output line → percent complete, plus the scan's milestone step (`N/5` beside the progress bar) |
| `DcuLog` | Pure parser for dcu-cli's `-outputLog`: extracts the authoritative "return code: N" line and classifies it per command via `Classify` (0/1/5 pass everywhere; a scan's 500 is a clean no-updates result; everything else is an error, described by name) |
| `DcuUpdate` | Pure row model for the detail pane's available-updates list: name, category, urgency badge, version transition, size |
| `RemoteError` (exception hierarchy) | Typed, severity-tagged remote failures: offline / unresolvable / RPC blocked / DCU not installed / launch fault / **connection lost** (psexec transport codes 233, 64, ...) / **timed out** (watchdog); `RemoteFailure` re-derives the reason from a worker message that crossed the runspace boundary |
| `ScanCacheDecision` | Pure rule: is a host's last scan still fresh enough to reuse (24h)? |
| `MachineInventory` / `InventoryFormat` | Per-machine probe DTO (model, service tag, battery health, disk, uptime) + label formatting |
| `MachineListShaper` | Pure mapper for the machine-list order: categorize a row (running / attention / online / offline) and rank categories worst-first for the list's fixed status-grouped sort |
| `HotkeyGesture` | Pure parse/build of hotkey gestures (`Ctrl+Alt+D` ↔ Win32 modifiers + virtual key ↔ WPF `Key`); rejects modifier-less and Shift-only combos |
| `TourStep` / `TourSteps` | The guided tour's ordered step content (title, body, target key, placement) — pure data so the tour is unit-tested headless |
| `DiskUsage*` (`FolderUsage`, `DiskUsageReport`, `WizTreeCsv`, `DiskUsageTree`, `FolderTreeNode`, `DiskUsageFormat`) | "Biggest folders on C:" DTO + WizTree CSV parse + path-containment tree builder + size formatting |
| `FolderDeletionPolicy` | Pure safety rule for the storage "Clear selected" action: is a scanned folder safe to clear? Canonicalizes the path first (resolves `..`, strips Windows' trailing dot/space, refuses 8.3 aliases) so the string lists can't be walked around, then blocks the volume root, the `Users` container, and protected system dirs (Windows/Program Files/ProgramData/…), with an allowlist for known caches (ccmcache, Temp, WU download, …). Drives the UI checkbox and is re-checked server-side |
| `AdSearchResult` / `AdFilter` | AD finder DTO + pure LDAP-filter construction, escaping, and lock/disable decode |
| `TempPassword` | Crypto-random phone-readable temp passwords (`Xxxxx-Xxxxx-99!` — no ambiguous glyphs, trailing special from `!#$%+=`) for the reset overlay, plus the plaintext→SecureString bridge (`ToSecure`) the lint rules require |
| `PersonLens` / `LensDevice` / `LensBitLockerKey` / `LensFormat` | User-Lens DTOs (a person's directory facts + their devices with OS / last domain logon / model + serial from SCCM hardware inventory / BitLocker keys) parsed from the lookup's JSON bundle, plus pure "last seen" formatting. The agent-side query lives in `src/Scripts/LensAgent.Common.ps1` (`Resolve-Lens`). `PersonLens.FromError` builds an empty lens carrying one failure, so a caller that never got a bundle can still show a reason |
| `PendingIntent` (+ `GatedAction`) | The action a de-elevated DONUT was asked to run, carried across the elevation restart. Untrusted input by construction: it holds only an action kind and host names, `FromJson` matches the action against the enum names (not `[enum]::TryParse`, which accepts a numeric string), and `DeleteFolders` is never resumable |
| `RecentConnection` | Typed view of one persisted "recent machine" entry backing the Home list (status, counts, cached inventory + disk usage); the persisting store is a Service |
| `DeviceFlowDecision` (+ `PollOutcome`) | Pure mapper: a GitHub device-flow poll result → continue / authorized / slow-down / fail |

## Core (`src/Core/`)

| Class | Purpose |
|-------|---------|
| `ConfigManager` | Load/save JSON config, directory initialization |
| `NetworkProbe` | Domain-controller-authoritative DNS resolution (cached DC discovery + `Resolve-DnsName -Server`, fail-hard), reverse-DNS validation, RPC/online checks |
| `AsyncJob` | Async job wrapper: runs each job as an isolated child `pwsh` process (via `WorkerProcess`) launched from a pool runspace, drains its output/result streams, and polls to completion |
| `WorkerProcess` | Child-process worker protocol: `Prepare` marshals args to a temp file, the `$Launcher` scriptblock spawns `RemoteWorker.ps1` as a separate `pwsh` process on a pool runspace, and `Interpret` reads back its JSON result — process isolation so parallel `using module` class-graph compiles can't deadlock |
| `ResolveProcessJob` | Fast-lane resolve: an `AsyncJob` whose slim, class-free `ResolveWorker.ps1` child is spawned **directly** (`Process.Start`, no pool slot). Polls `HasExited` + a result file on the pump; a 30 s watchdog `Kill()`s a wedge; `ProcessFault` (no verdict) triggers the classic-path fallback |
| `RunspaceManager` | Static management of **two** RunspacePools: the worker pool sized to `throttleLimit` (`AsyncJob`) and a fixed 3-runspace interactive pool (`PoolScriptJob`), so a fleet-wide scan holding every worker runspace can't starve the lookups a user is waiting on. Both `min = max`; raises the .NET ThreadPool floor to cover both before creating either, so dispatch/completion callbacks can't starve |
| `PoolScriptJob` | Shared mechanics for in-process pool scripts (AD search, Lens broker, unlock, startup task): start on the **interactive** pool, complete + dispose, async-stop (`BeginStop`, never a blocking `Dispose` on a running pipeline) and terminal-state reaping. The envelope stays `@{ Ps; Handle }` so poll loops attach per-job state |
| `HostListSource` | Resolves and reads the bundled host list (e.g. `WSID.txt`) |
| `TimeFormat` | Pure time helpers: relative labels (`2m ago`) + ISO8601 parse (`ParseIso`, blank → MinValue) |
| `BuildProvenance` | Startup provenance stamp: logs the running build's git SHA/version + runtime facts so field logs identify exactly which build produced them |
| `LogService` | Thread-safe leveled logging (`[INFO]/[WARN]/[ERROR]/[DEBUG]`) to file, with exception + structured helpers and a `NullLogService` no-op. `DEBUG` is gated by `DebugEnabled` (the `debugLogging` setting / `-DebugLog` override); other levels always flow |
| `ViewLoader` | The one runtime XAML loader (`XamlReader.Load` with stream-dispose so files never stay locked; throws on missing). Page loads wrap it in catch-and-null; `HomePresenter.ComposeRegions` calls it bare so a broken region fails the boot loudly. Each returned root owns its file's namescope |
| `DispatcherWatchdog` | **Permanent diagnostic:** a `DispatcherTimer` that logs when the UI thread stalls past a threshold, with GC-generation deltas to fingerprint the cause (loader-lock vs blocking GC). Pinned the 2026-07 freeze class; kept because it costs one timer and is the first evidence line for any future stall |
| `DonutPaths` | Resolves the one machine-wide data root (`%ProgramData%\DONUT\data`) and its config / logs / reports folders, plus the ACL that lets an elevated and a de-elevated instance share it. Replaces the per-account `%LOCALAPPDATA%` layout, which split into two stores once the UI could run as a different user |
| `ElevationContext` (+ `ElevationState`) | The one place that reads the process token: `IsElevated` (Administrators group), `IsSystem` (the narrower service-token question), `CurrentIdentityName`. `Classify` is the pure rule the UI gates on, returning `NotRequired` / `Satisfied` / `RelaunchRequired`; it takes the elevation state as a parameter so the decision is testable off Windows |

## Services (`src/Services/`)

All remote services subclass `RemoteJobService` (shared worker-arg building; lives in
`RemoteServices.psm1`); they only **prepare/parse** off the UI thread — the worker does
the network I/O.

| Class | Purpose |
|-------|---------|
| `ExecutionService` (`WorkerServices.psm1`) | Remote PsExec execution, DCU CLI invocation, per-phase dispatch (resolve/scan/apply/inventory/disk/delete), artifact copy |
| `ScanService` (`RemoteServices.psm1`) | Prepare scan operations |
| `RemoteUpdateService` (`RemoteServices.psm1`) | Prepare update scan/apply; parse + count the update report and build the detail pane's typed `DcuUpdate` rows (driver-matched, urgency-sorted) |
| `InventoryService` | Prepare + parse the per-machine CIM inventory probe |
| `DiskUsageService` | Prepare + parse the on-demand WizTree "biggest folders" scan |
| `HostResolver` | Start-early IP-resolution cache (warm the active DC, prefetch on select); builds worker args for both lanes (`PrepareResolve` classic, `PrepareResolveFast` slim child) |
| `ActiveDirectoryService` | Live multi-forest AD search (computers + users; run on the pool via `AdSearchWorker`, one job per forest), account unlock, and temp-password reset (`ResetPassword` → `InvokeReset` seam; both on the pool, password never logged) |
| `PersonLensService` | User Lens: resolves a person to their directory facts + SCCM devices + BitLocker keys, run **de-elevated as the logged-on user** (see [User Lens](./user-lens.md)); parses the worker's JSON bundle (the de-elevation is an overridable seam) |
| `DriverMatchingService` | Brand-based driver/update matching with category support |
| `StartupTaskService` | Start-with-Windows: builds the launch spec, reconciles the `DONUT-<console user>` scheduled task (register / update / unregister / stale-sweep) against the toggle. One lane - the logon trigger and the principal are both the console user, at `RunLevel Highest`, so an admin console account starts elevated with no logon-time UAC prompt (on a non-admin account it degrades to the standard token and DONUT elevates on demand). Failures surface their real reason via `LastFailure` |
| `PendingIntentStore` | Persists the one gated click that asked for elevation and claims it back once after the restart. `Take` deletes the file before returning, so a note fires at most once; the filesystem touch points are overridable seams |
| `RecentConnectionsStore` | Persists the "recent machines" entries in `AppConfig.Settings['recentHosts']`: upsert/seed/cap/sort + coalesced saves through the config manager |
| `SystemInfoService` | Local machine facts (identity, domain, battery) for the title bar |
| `SelfUpdateService` | GitHub releases, token management, MSI verification |
| `ResourceService` | XAML resource dictionary loading |

## ViewModels (`src/UI/ViewModels/`)

All inherit the C# `Donut.Mvvm.ObservableObject` base unless noted; commands are
`RelayCommand`s wired by the owning presenter.

| Class | Purpose |
|-------|---------|
| `HomeViewModel` | The Home page: `Machines` (bound to the virtualizing ListBox), `SelectedMachine`, and the AD finder's `SearchResults` |
| `HostViewModel` | One machine row + the detail pane it mirrors: status dot/chip/progress/step text, the status sort-rank, overview-strip facts, the IP subtitle (probe freshness stays on the card — Reduction), the available-updates list, folders tree, Run/Gather commands |
| `FolderNodeViewModel` | Display-ready largest-folders tree node (pure, computed per report) |
| `SearchRowViewModel` | AD finder dropdown row — section header, "Add as a machine" action, or result, with Pick/Unlock/Reset commands (pure) |
| `PersonLensViewModel` / `LensDeviceViewModel` | The user Lens shown in the detail pane: person fields + a device collection, each device with a Reveal-BitLocker toggle and an Add-to-machine-list command |
| `ToastViewModel` | One toast card (title/message/accent/IsClosing for the exit animation) |
| `DialogViewModel` | One modal dialog's content (title/message/list/buttons + verdict commands) |
| `LoginViewModel` | Login window content (output text + AuthCommand) |
| `ResetPasswordViewModel` | The temp-password reset overlay: target user, visible password field, change-at-logon flag (default on), Generate/Copy/QR/Apply commands; `SetTarget` re-arms fresh defaults, `ClearSecrets` wipes on close |
| `MainViewModel` | Shell: OpenSettings/CloseSettings + OpenTour/CloseTour commands, window chrome commands, IsSettingsOpen, IsTourOpen, and the QR (`IsQrOpen`/`QrCaption`/`QrHint`) + reset (`IsResetOpen`/`ResetVm`) overlays |

The settings option forms have no view-model by design — they stay on
`SettingsPresenter`'s data-driven binder (every named control maps 1:1 to a dcu-cli arg
key), and settings persist in real time, so there is no Save command.

## Presenters (`src/UI/Presenters/`)

Coordinators/services: they own the engine objects and build/wire the view-models. See
[Design decisions](./overview.md#design-decisions) for the back-ref seam that links them.

| Class | Purpose |
|-------|---------|
| `MainPresenter` | Composition root: main window, lazy Settings construction, the settings/QR/reset-password overlays (the reset runs `AdResetPasswordWorker` via `RunOnPool`), shell command targets, and the tray/hotkey/autostart wiring (`AttachHotkey`, `ApplyHotkey`, `ApplyStartupTask`) |
| `AsyncJobPresenter` | Base class: pumps queued `AsyncJob`s on a `DispatcherTimer` (poll → settle) |
| `HomePresenter` | Owns the `AsyncJob` pump, the add/scan/apply run flow, the machine rows/list (status-grouped sort), and housekeeping. Composes the Home shell's regions (`ComposeRegions` + `FindHomeElement`, the tour's cross-namescope probe). Delegates the detail panel to `InventoryPresenter`, resolve/warm to `ResolutionCoordinator`, and the search-bar finder + Lens to `FinderPresenter` |
| `InventoryPresenter` | The per-machine detail panel: header + overview render, the job log, the CIM inventory probe and WizTree storage scan (execution + completion), and machine selection. Its `Inventory` / `DiskScan` jobs are drained by `HomePresenter`'s pump and forwarded back to it. Offline-class probe failures flip the host's reachability verdict (`ReflectFailure`) instead of vanishing into the log |
| `ResolutionCoordinator` | The `Resolve` job lifecycle and runspace-pool warm: start-early IP resolution via the shared `HostResolver` (fast lane by default — capped direct `ResolveProcessJob` children with a FIFO overflow queue, classic worker path as the per-fault fallback and after the 3-fault latch), verdict caching, and DC discovery/persist. When a verdict lands it re-issues queued runs/gathers through `HomePresenter`'s seam methods |
| `FinderPresenter` | The search bar's live multi-forest AD finder (debounced in-process search on the pool via `AdSearchWorker`, one job per forest + inline unlock) and the **user Lens** (de-elevated agent lookup, partial streaming, in-memory TTL cache); raw pool jobs polled on `DispatcherTimer`s. Calls back into `HomePresenter`'s machine seams (`PrefetchIp`, `EnsureRow`, `StartInventory`, `MoveRowToTop`, `UpdateEmptyHint`) via the duck-typed back-ref |
| `SettingsPresenter` | Hosted in the settings overlay (naming rule: Settings* is the UI surface, Config/`AppConfig`/`ConfigManager` is the persisted state it edits): command selection, the data-driven option-form binder, and real-time persistence (args on edit, toggles on change) with side-effect hooks for the hotkey and startup task |
| `KeybindRecorder` | Wraps one keybind field (display + Record + Clear): captures modifiers + one key live, commits through `HotkeyGesture.FromKeys`, Esc cancels |

### Home page regions (`src/UI/Views/Home/`)

The Home page is a slot-frame shell (`HomeView.xaml`) composing one file per region; each
region root owns its file's namescope, and exactly one presenter adopts each root:

| Region file | Root name | Adopted by | Names it owns |
|-------------|-----------|------------|---------------|
| `ActionBar.xaml` | — | `FinderPresenter` (+ `HomePresenter` for mode/run-all) | `SearchBox`, `GoogleSearchBar`, `SearchResultsPopup`, `SearchResultsList`, `btnMode`, `txtMode`, `btnRunAll` |
| `StatCards.xaml` | — | binding-only (`SelectedMachine.Ov*`) | — |
| `MachinePane.xaml` | `MachinePanel` | `HomePresenter` | `btnClearTabs`, `MachineList`, `FleetEmptyHint` |
| `DetailPane.xaml` | `DetailPane` | `InventoryPresenter` | `btnDetailRefresh`, `btnFindFolders`, `btnDeleteFolders`, `lstDetailLog`, `btnCopyLog`, `DetailProgress`, `DiskFoldersList`, `slotLens` |
| `LensPane.xaml` (nested in DetailPane) | `LensPanel` | binding-only (`SelectedPerson`) | — |
| `TrayPresenter` | The system-tray icon and menu: show/toggle the window, exit, the close-to-tray hint balloon, and the second-launch show-request listener |
| `TourPresenter` | The first-run guided tour: spotlight + callout per `TourStep`, Back/Next/Skip navigation, first-run auto-start (`hasSeenTour`) and `?`-button replay |
| `LoginPresenter` | GitHub Device Flow: poll timer + modal lifecycle behind `LoginViewModel` |
| `UpdatePresenter` | Self-update check and prompt |
| `DialogPresenter` | Dialog service: shows the modal `DialogWindow`, returns the verdict |
| `ToastService` | Enqueues `ToastViewModel`s + owns the auto-dismiss/exit-animation timers |

## Diagrams

The class structure is split per subsystem; each diagram is embedded on its
subsystem page:

- [Runspaces and workers](./runspaces-and-workers.md) - `class_runspaces.svg`
- [Remote execution](./remote-execution.md) - `class_remote_exec.svg`
- [User Lens](./user-lens.md) - `class_lens.svg`
- [UI and threading](./ui-and-threading.md) - `class_ui.svg`
- [Configuration and persistence](./configuration-and-persistence.md) - `class_config.svg`

Component wiring, launcher → scripts → presenters → services → workers, is on
the [architecture overview](./overview.md#component-view).
