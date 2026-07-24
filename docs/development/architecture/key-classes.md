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
| `JobStatus` / `JobKind` (enums) | Job lifecycle state and the kind of remote operation (`Scan`, `UpdateScan`, `UpdateApply`, `Inventory`, `DiskScan`, `Resolve`) |
| `FleetCardStatus` | Pure mapper: a job's (type, status, reboot) → card label, colour key, busy flag |
| `DcuProgress` | Pure parser: a DCU output line → percent complete, plus the scan's milestone step (`N/5` beside the progress bar) |
| `DcuLog` | Pure parser for dcu-cli's `-outputLog`: extracts the authoritative "return code: N" line and classifies it (only {0, 1, 5} are success/reboot; everything else is an error) |
| `DcuUpdate` | Pure row model for the detail pane's available-updates list: name, category, urgency badge, version transition, size |
| `RemoteError` (exception hierarchy) | Typed, severity-tagged remote failures: offline / unresolvable / RPC blocked / DCU not installed / launch fault / **connection lost** (psexec transport codes 233, 64, ...) / **timed out** (watchdog); `RemoteFailure` re-derives the reason from a worker message that crossed the runspace boundary |
| `ScanCacheDecision` | Pure rule: is a host's last scan still fresh enough to reuse (24h)? |
| `MachineInventory` / `InventoryFormat` | Per-machine probe DTO (model, service tag, battery health, disk, uptime) + label formatting |
| `MachineListShaper` | Pure mapper for the machine-list order: categorize a row (running / attention / online / offline) and rank categories worst-first for the list's fixed status-grouped sort |
| `MachineNameMatcher` | Pure classifier for search text: does it look like a machine name (config-editable regex patterns, e.g. `^CAP-`) or match an AD computer exactly? Drives the finder's "Add as a machine" pre-selection |
| `HotkeyGesture` | Pure parse/build of hotkey gestures (`Ctrl+Alt+D` ↔ Win32 modifiers + virtual key ↔ WPF `Key`); rejects modifier-less and Shift-only combos |
| `TourStep` / `TourSteps` | The guided tour's ordered step content (title, body, target key, placement) — pure data so the tour is unit-tested headless |
| `DiskUsage*` (`FolderUsage`, `DiskUsageReport`, `WizTreeCsv`, `DiskUsageTree`, `FolderTreeNode`, `DiskUsageFormat`) | "Biggest folders on C:" DTO + WizTree CSV parse + path-containment tree builder + size formatting |
| `FolderDeletionPolicy` | Pure safety rule for the storage "Delete selected" action: is a scanned folder safe to remove? Blocks the volume root, the `Users` container, and protected system dirs (Windows/Program Files/ProgramData/…). Drives the UI checkbox and is re-checked server-side |
| `AdSearchResult` / `AdFilter` | AD finder DTO + pure LDAP-filter construction, escaping, and lock/disable decode |
| `PersonLens` / `LensDevice` / `LensBitLockerKey` / `LensFormat` | User-Lens DTOs (a person's directory facts + their devices with OS / last domain logon / BitLocker keys) parsed from the lookup's JSON bundle, plus pure "last seen" formatting |
| `RecentConnection` / `RecentConnectionsStore` | Persisted "recent machines" backing the Home list (status, counts, cached inventory + disk usage) |
| `DeviceFlowDecision` (+ `PollOutcome`) | Pure mapper: a GitHub device-flow poll result → continue / authorized / slow-down / fail |

## Core (`src/Core/`)

| Class | Purpose |
|-------|---------|
| `ConfigManager` | Load/save JSON config, directory initialization |
| `NetworkProbe` | Domain-controller-authoritative DNS resolution (cached DC discovery + `Resolve-DnsName -Server`, fail-hard), reverse-DNS validation, RPC/online checks |
| `AsyncJob` | Async job wrapper: runs each job as an isolated child `pwsh` process (via `WorkerProcess`) launched from a pool runspace, drains its output/result streams, and polls to completion |
| `WorkerProcess` | Child-process worker protocol: `Prepare` marshals args to a temp file, the `$Launcher` scriptblock spawns `RemoteWorker.ps1` as a separate `pwsh` process on a pool runspace, and `Interpret` reads back its JSON result — process isolation so parallel `using module` class-graph compiles can't deadlock |
| `RunspaceManager` | Static RunspacePool management for parallel execution; also raises the .NET ThreadPool floor before pool creation so dispatch/completion callbacks can't starve |
| `HostListSource` | Resolves and reads the bundled host list (e.g. `WSID.txt`) |
| `TimeFormat` | Pure "relative time" formatter (`2m ago`) |
| `LogService` | Thread-safe leveled logging (`[INFO]/[WARN]/[ERROR]/[DEBUG]`) to file, with exception + structured helpers and a `NullLogService` no-op |
| `DispatcherWatchdog` | **Diagnostic (temporary):** a `DispatcherTimer` that logs when the UI thread stalls past a threshold, to pin the intermittent disk-scan-mid-scan freeze (suspected CLR loader-lock contention). Paired with per-phase timing in `ExecutionService.RunDiskScanPhase`; both are removed once the freeze is pinned |

## Services (`src/Services/`)

All remote services subclass `RemoteJobService` (shared worker-arg building); they
only **prepare/parse** off the UI thread — the worker does the network I/O.

| Class | Purpose |
|-------|---------|
| `ExecutionService` | Remote PsExec execution, DCU CLI invocation, per-phase dispatch (resolve/scan/apply/inventory/disk), artifact copy |
| `ScanService` | Prepare scan operations |
| `RemoteUpdateService` | Prepare update scan/apply with driver matching; parse + count the update report |
| `InventoryService` | Prepare + parse the per-machine CIM inventory probe |
| `DiskUsageService` | Prepare + parse the on-demand WizTree "biggest folders" scan |
| `HostResolver` | Start-early IP-resolution cache (warm the active DC, prefetch on select) |
| `ActiveDirectoryService` | Live multi-forest AD search (computers + users; run on the pool via `AdSearchWorker`, one job per forest) and account unlock (on the pool) |
| `PersonLensService` | User Lens: resolves a person to their directory facts + SCCM devices + BitLocker keys, run **de-elevated as the logged-on user** (see [Implementation notes](./implementation-notes.md#de-elevating-the-user-lens)); parses the worker's JSON bundle (the de-elevation is an overridable seam) |
| `DriverMatchingService` | Brand-based driver/update matching with category support |
| `StartupTaskService` | Start-with-Windows: builds the launch spec, reconciles the per-user `DONUT-<user>` scheduled task (register / update / unregister) against the toggle |
| `SystemInfoService` | Local machine facts (identity, domain, battery) for the title bar |
| `SelfUpdateService` | GitHub releases, token management, MSI verification |
| `ResourceService` | XAML resource dictionary loading |

## ViewModels (`src/UI/ViewModels/`)

All inherit the C# `Donut.Mvvm.ObservableObject` base unless noted; commands are
`RelayCommand`s wired by the owning presenter.

| Class | Purpose |
|-------|---------|
| `HomeViewModel` | The Home page: `Machines` (bound to the virtualizing ListBox), `SelectedMachine`, and the AD finder's `SearchResults` |
| `HostViewModel` | One machine row + the detail pane it mirrors: status dot/chip/progress/step text, the status sort-rank, overview-strip facts, probed subtitle, the available-updates list, folders tree, Run/Gather commands |
| `FolderNodeViewModel` | Display-ready largest-folders tree node (pure, computed per report) |
| `SearchRowViewModel` | AD finder dropdown row — section header, "Add as a machine" action, or result, with Pick/Unlock commands (pure) |
| `PersonLensViewModel` / `LensDeviceViewModel` | The user Lens shown in the detail pane: person fields + a device collection, each device with a Reveal-BitLocker toggle and an Add-to-machine-list command |
| `ToastViewModel` | One toast card (title/message/accent/IsClosing for the exit animation) |
| `DialogViewModel` | One modal dialog's content (title/message/list/buttons + verdict commands) |
| `LoginViewModel` | Login window content (output text + AuthCommand) |
| `MainViewModel` | Shell: OpenSettings/CloseSettings + OpenTour/CloseTour commands, window chrome commands, IsSettingsOpen, IsTourOpen |

The settings option forms have no view-model by design — they stay on
`ConfigPresenter`'s data-driven binder (every named control maps 1:1 to a dcu-cli arg
key), and settings persist in real time, so there is no Save command.

## Presenters (`src/UI/Presenters/`)

Coordinators/services: they own the engine objects and build/wire the view-models. See
[Design decisions](./overview.md#design-decisions) for the back-ref seam that links them.

| Class | Purpose |
|-------|---------|
| `MainPresenter` | Composition root: main window, lazy Config construction, the settings overlay, shell command targets, and the tray/hotkey/autostart wiring (`AttachHotkey`, `ApplyHotkey`, `ApplyStartupTask`) |
| `AsyncJobPresenter` | Base class: pumps queued `AsyncJob`s on a `DispatcherTimer` (poll → settle) |
| `HomePresenter` | Owns the `AsyncJob` pump, the add/scan/apply run flow, the machine rows/list (status-grouped sort), and housekeeping. Delegates the detail panel to `InventoryPresenter`, resolve/warm to `ResolutionCoordinator`, and the search-bar finder + Lens to `FinderPresenter` |
| `InventoryPresenter` | The per-machine detail panel: header + overview render, the job log, the CIM inventory probe and WizTree storage scan (execution + completion), and machine selection. Its `Inventory` / `DiskScan` jobs are drained by `HomePresenter`'s pump and forwarded back to it |
| `ResolutionCoordinator` | The `Resolve` job lifecycle and runspace-pool warm: start-early IP resolution via the shared `HostResolver`, verdict caching, and DC discovery/persist. When a verdict lands it re-issues queued runs/gathers through `HomePresenter`'s seam methods |
| `FinderPresenter` | The search bar's live multi-forest AD finder (debounced in-process search on the pool via `AdSearchWorker`, one job per forest + inline unlock) and the **user Lens** (de-elevated agent lookup, partial streaming, in-memory TTL cache); raw pool jobs polled on `DispatcherTimer`s. Calls back into `HomePresenter`'s machine seams (`PrefetchIp`, `EnsureRow`, `StartInventory`, `MoveRowToTop`, `UpdateEmptyHint`) via the duck-typed back-ref |
| `ConfigPresenter` | Hosted in the settings overlay: command selection, the data-driven option-form binder, and real-time persistence (args on edit, toggles on change) with side-effect hooks for the hotkey and startup task |
| `KeybindRecorder` | Wraps one keybind field (display + Record + Clear): captures modifiers + one key live, commits through `HotkeyGesture.FromKeys`, Esc cancels |
| `TrayPresenter` | The system-tray icon and menu: show/toggle the window, exit, the close-to-tray hint balloon, and the second-launch show-request listener |
| `TourPresenter` | The first-run guided tour: spotlight + callout per `TourStep`, Back/Next/Skip navigation, first-run auto-start (`hasSeenTour`) and `?`-button replay |
| `LoginPresenter` | GitHub Device Flow: poll timer + modal lifecycle behind `LoginViewModel` |
| `UpdatePresenter` | Self-update check and prompt |
| `DialogPresenter` | Dialog service: shows the modal `DialogWindow`, returns the verdict |
| `ToastService` | Enqueues `ToastViewModel`s + owns the auto-dismiss/exit-animation timers |

## Diagrams

The full class structure across all layers:

![DONUT class diagram](/diagrams/class_diagram.svg)

*Source: [`class_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_diagram.puml)*

Component wiring, launcher → scripts → presenters → services → workers:

![DONUT component diagram](/diagrams/component_diagram.svg)

*Source: [`component_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/component_diagram.puml)*
