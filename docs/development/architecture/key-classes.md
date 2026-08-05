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
| `JobStatus` / `JobKind` (enums, `JobEnums.psm1`) | Job lifecycle state and the kind of remote operation |
| `LogLine` (+ `LogSeverity`) | One typed terminal line: severity + normalized `HH:mm:ss` stamp + text |
| `FleetCardStatus` | Pure mapper: a job's (type, status, reboot) → card label, colour key, busy flag |
| `DcuProgress` | Pure parser: a DCU output line → percent complete + milestone step |
| `DcuLog` | Pure parser for dcu-cli's `-outputLog`: extracts the authoritative "return code: N" line and classifies it per command (`Classify`) |
| `DcuUpdate` | Pure row model for the available-updates list: name, category, urgency, version transition, size |
| `RemoteError` (exception hierarchy) | Typed, severity-tagged remote failures (offline / unresolvable / RPC blocked / DCU missing / launch fault / connection lost / timed out) |
| `ScanCacheDecision` | Pure rule: is a host's last scan still fresh enough to reuse (24h)? |
| `MachineInventory` / `InventoryFormat` | Per-machine probe DTO + label formatting |
| `MachineListShaper` | Pure mapper for the machine-list order: categorize a row and rank categories worst-first |
| `HotkeyGesture` | Pure parse/build of hotkey gestures; rejects modifier-less and Shift-only combos |
| `TourStep` / `TourSteps` | The guided tour's ordered step content — pure data, unit-tested headless |
| `DiskUsage*` | "Biggest folders" DTOs + WizTree CSV parse + path-containment tree builder + size formatting |
| `FolderDeletionPolicy` | Pure safety rule for "Clear selected": canonicalizes the path (resolves `..`, strips trailing dot/space, refuses 8.3 aliases), blocks the volume root and protected system dirs, allowlists known caches. Drives the UI checkbox and is re-checked server-side |
| `AdSearchResult` / `AdFilter` | AD finder DTO + pure LDAP-filter construction, escaping, and lock/disable decode |
| `TempPassword` | Crypto-random phone-readable temp passwords + the plaintext→SecureString bridge |
| `PersonLens` / `LensDevice` / `LensBitLockerKey` / `LensFormat` | User-Lens DTOs parsed from the lookup's JSON bundle; `FromError` builds an empty lens carrying one failure |
| `PendingIntent` (+ `GatedAction`) | The gated action carried across the elevation restart — untrusted by construction (enum names only; `DeleteFolders` never resumable) |
| `RecentConnection` | Typed view of one persisted "recent machine" entry |
| `DeviceFlowDecision` (+ `PollOutcome`) | Pure mapper: a GitHub device-flow poll result → continue / authorized / slow-down / fail |

## Core (`src/Core/`)

| Class | Purpose |
|-------|---------|
| `ConfigManager` | Load/save JSON config, directory initialization |
| `NetworkProbe` | DC-authoritative DNS resolution (cached DC discovery, fail-hard), reverse-DNS validation, RPC/online checks |
| `AsyncJob` | Async job wrapper: runs each job as an isolated child `pwsh` process, drains its streams, polls to completion |
| `WorkerProcess` | Child-process worker protocol: args to temp file, launcher scriptblock, JSON result back |
| `ResolveProcessJob` | Fast-lane resolve: a slim class-free child spawned directly, no pool slot; a 30 s watchdog kills a wedge |
| `RunspaceManager` | Static management of the two pools: worker (`throttleLimit`) and interactive (fixed 4); raises the ThreadPool floor before creating either |
| `PoolScriptJob` | Shared mechanics for in-process interactive-pool scripts: start, complete, async-stop, reap |
| `HostListSource` | Resolves and reads the bundled host list |
| `TimeFormat` | Pure time helpers: relative labels + ISO8601 parse |
| `BuildProvenance` | Startup provenance stamp (git SHA / version + runtime facts) |
| `LogService` | Thread-safe leveled logging to file; `DEBUG` gated by `DebugEnabled`; `NullLogService` no-op |
| `ViewLoader` | The one runtime XAML loader; each returned root owns its file's namescope |
| `DispatcherWatchdog` | Permanent diagnostic: logs UI-thread stalls with GC-generation deltas to fingerprint the cause |
| `DonutPaths` | Resolves the machine-wide data root and its folders, plus the shared ACL |
| `ElevationContext` | The one place that reads the process token: `IsElevated`, `IsSystem`, `InteractiveUser` |

## Services (`src/Services/`)

All remote services subclass `RemoteJobService` (shared worker-arg building); they
only **prepare/parse** off the UI thread — the worker does the network I/O.

| Class | Purpose |
|-------|---------|
| `ExecutionService` (`WorkerServices.psm1`) | Remote PsExec execution, DCU CLI invocation, per-phase dispatch, artifact copy |
| `RemoteUpdateService` | Prepare DCU scan/apply; parse the report into typed `DcuUpdate` rows |
| `InventoryService` | Prepare + parse the per-machine CIM inventory probe |
| `DiskUsageService` | Prepare + parse the WizTree "biggest folders" scan |
| `HostResolver` | Start-early IP-resolution cache; builds worker args for both resolve lanes |
| `ActiveDirectoryService` | Live multi-forest AD search, account unlock, temp-password reset (password never logged) |
| `PersonLensService` | User Lens transport: agent supervision + the encrypted exchange ([User Lens](./user-lens.md)) |
| `DriverMatchingService` | Brand-based driver/update matching |
| `StartupTaskService` | Start-with-Windows: reconciles the `DONUT-<console user>` scheduled task against the toggle; failures surface via `LastFailure` |
| `PendingIntentStore` | Persists the one gated click across elevation; `Take` deletes before returning so a note fires at most once |
| `RecentConnectionsStore` | Persists recents in `config\recents.json` (cap 50, de-duplicated, coalesced saves) |
| `SelfUpdateService` | GitHub releases, token management, MSI verification |
| `ResourceService` | XAML resource dictionary loading |

## ViewModels (`src/UI/ViewModels/`)

All inherit the C# `Donut.Mvvm.ObservableObject` base; commands are `RelayCommand`s
wired by the owning presenter.

| Class | Purpose |
|-------|---------|
| `HomeViewModel` | The Home page: `Machines`, `SelectedMachine`, and the finder's `SearchResults` |
| `HostViewModel` | One machine row + the detail pane it mirrors: status dot/chip/progress, overview facts, updates list, folders tree, commands |
| `FolderNodeViewModel` | Display-ready largest-folders tree node |
| `SearchRowViewModel` | Finder dropdown row — header or result, with Pick/Unlock/Reset commands |
| `PersonLensViewModel` / `LensDeviceViewModel` | The user Lens: person fields + devices, each with Reveal-BitLocker and Add commands |
| `ToastViewModel` | One toast card |
| `DialogViewModel` | One modal dialog's content + verdict commands |
| `LoginViewModel` | Login window content |
| `ResetPasswordViewModel` | The temp-password overlay: target, password field, change-at-logon flag, Generate/Copy/QR/Apply; `ClearSecrets` wipes on close |
| `MainViewModel` | Shell: settings/tour/QR/reset overlay state + window chrome commands |

The settings option forms have no view-model by design — they stay on
`SettingsPresenter`'s data-driven binder, and settings persist in real time, so
there is no Save command.

## Presenters (`src/UI/Presenters/`)

Coordinators/services: they own the engine objects and build/wire the view-models.
See [the coordinator seam](../decisions.md#the-coordinator-seam).

| Class | Purpose |
|-------|---------|
| `MainPresenter` | Composition root: main window, lazy Settings construction, the overlays, shell command targets, tray/hotkey/autostart wiring |
| `AsyncJobPresenter` | Base class: pumps queued `AsyncJob`s on a `DispatcherTimer` |
| `HomePresenter` | The `AsyncJob` pump, add/scan/apply run flow, machine rows, and Home region composition; delegates detail, resolve, and finder work to the coordinators below |
| `InventoryPresenter` | The per-machine detail panel: overview render, job log, inventory probe, storage scan, machine selection |
| `ResolutionCoordinator` | The `Resolve` job lifecycle and pool warm: fast lane + classic fallback, verdict caching, DC discovery |
| `FinderPresenter` | The search bar's live multi-forest AD finder + the user Lens (agent lookup, partial streaming, TTL cache) |
| `SettingsPresenter` | Command selection, the data-driven option-form binder, and real-time persistence with side-effect hooks |
| `KeybindRecorder` | Wraps one keybind field: captures modifiers + key live, commits through `HotkeyGesture.FromKeys` |
| `TrayPresenter` | The system-tray icon and menu, the close-to-tray hint, the second-launch show-request listener |
| `TourPresenter` | The guided tour: spotlight + callout per `TourStep`, first-run auto-start, `?` replay |
| `LoginPresenter` | GitHub Device Flow: poll timer + modal lifecycle |
| `UpdatePresenter` | Self-update check and prompt |
| `DialogPresenter` | Dialog service: shows the modal `DialogWindow`, returns the verdict |
| `ToastService` | Enqueues `ToastViewModel`s + the auto-dismiss timers |

### Home page regions (`src/UI/Views/Home/`)

The Home page is a slot-frame shell (`HomeView.xaml`) composing one file per
region; each region root owns its file's namescope, and exactly one presenter
adopts each root:

| Region file | Root name | Adopted by | Names it owns |
|-------------|-----------|------------|---------------|
| `ActionBar.xaml` | — | `FinderPresenter` (+ `HomePresenter` for mode/run-all) | `SearchBox`, `GoogleSearchBar`, `SearchResultsPopup`, `SearchResultsList`, `btnMode`, `txtMode`, `btnRunAll` |
| `StatCards.xaml` | — | binding-only (`SelectedMachine.Ov*`) | — |
| `MachinePane.xaml` | `MachinePanel` | `HomePresenter` | `btnClearTabs`, `MachineList`, `FleetEmptyHint` |
| `DetailPane.xaml` | `DetailPane` | `InventoryPresenter` | `btnDetailRefresh`, `btnFindFolders`, `btnDeleteFolders`, `lstDetailLog`, `btnCopyLog`, `DetailProgress`, `DiskFoldersList`, `slotLens` |
| `LensPane.xaml` (nested in DetailPane) | `LensPanel` | binding-only (`SelectedPerson`) | — |

## Diagrams

The class structure is split per subsystem; each diagram is embedded on its
subsystem page:

- [Runspaces and workers](./runspaces-and-workers.md) - `class_runspaces.svg`
- [Remote execution](./remote-execution.md) - `class_remote_exec.svg`
- [User Lens](./user-lens.md) - `class_lens.svg`
- [UI and threading](./ui-and-threading.md) - `class_ui.svg`
- [Elevation and autostart](./elevation.md) - `class_config.svg`

Component wiring, launcher → scripts → presenters → services → workers, is on the
[architecture overview](./overview.md#component-view).
