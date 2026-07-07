<h1> DONUT Architecture </h1>

How DONUT is built: a WPF/PowerShell tool that runs the Dell Command Update (DCU)
CLI remotely across many Dell machines in parallel, with a per-machine detail panel,
a live Active Directory finder, and a de-elevated user Lens. This is the standing
architecture reference; the visual counterpart is [`docs/diagrams/`](diagrams/) (see
its [index](diagrams/README.md)). Comment/layout conventions live in
[`Coding-Style.md`](Coding-Style.md).

> The project began as a script-based tool and was refactored to an OOP structure,
> first to a Passive-View MVP and then to MVVM. That migration is complete; this
> document describes the result, not the plan.

<h2> Table of Contents </h2>

- [1. Directory Structure](#1-directory-structure)
- [2. Architecture (MVVM)](#2-architecture-mvvm)
  - [The Layers](#the-layers)
  - [The MVVM bases](#the-mvvm-bases)
  - [Presenters are coordinators](#presenters-are-coordinators)
  - [Design decisions](#design-decisions)
- [3. Key Classes](#3-key-classes)
  - [Models (`src/Models/`)](#models-srcmodels)
  - [Core (`src/Core/`)](#core-srccore)
  - [Services (`src/Services/`)](#services-srcservices)
  - [ViewModels (`src/UI/ViewModels/`)](#viewmodels-srcuiviewmodels)
  - [Presenters (`src/UI/Presenters/`)](#presenters-srcuipresenters)
- [4. Runtime Flows](#4-runtime-flows)
- [5. Implementation Notes](#5-implementation-notes)
  - [Parallel Execution (Runspaces)](#parallel-execution-runspaces)
  - [Remote Execution (PsExec)](#remote-execution-psexec)
  - [De-elevating the user Lens](#de-elevating-the-user-lens)
  - [UI \& Threading](#ui--threading)
  - [Configuration \& Persistence](#configuration--persistence)
  - [PowerShell Constraints to Retain](#powershell-constraints-to-retain)
- [6. Testing](#6-testing)
- [7. Code Coverage](#7-code-coverage)

## 1. Directory Structure

The structure emphasizes testability and a layered UI architecture.

```text
root/
├── assets/                 <-- Assets
│   ├── Images/
│   └── Screenshots/
├── bin/                    <-- Binaries/Dependencies
├── docs/                   <-- Documentation (this file, Coding-Style, diagrams/)
├── src/                    <-- Source Code
│   ├── Core/               <-- Base classes, enums, infrastructure (reusable)
│   ├── Models/             <-- Data classes (DTOs) + pure mappers
│   ├── Services/           <-- Business logic (DONUT-specific)
│   ├── Scripts/            <-- Standalone scripts + remote workers
│   ├── UI/                 <-- UI Layer
│   │   ├── Views/          <-- XAML files (templates + bindings)
│   │   ├── Styles/         <-- XAML styles
│   │   ├── ViewModels/     <-- Bindable state + commands
│   │   ├── Presenters/     <-- Coordinators / UI services (jobs, timers, dialogs)
│   └── Launcher/           <-- C# Launcher project (+ Donut.Mvvm base types)
├── tests/                  <-- Pester tests
│   ├── Unit/
│   └── Integration/
├── README.md
└── LICENSE

Runtime Data Location:

%LOCALAPPDATA%/DONUT/
├── logs/                   <-- Runtime generated logs
├── reports/                <-- Runtime generated reports
├── config/                 <-- Configuration files
└── InstallWorker.ps1       <-- Copied during update
```

`Models`, `Services`, and `Core` separate concerns explicitly: 
- **Models** are pure data structures and mappers (DTOs).
- **Services** hold DONUT-specific business logic.
- **Core** is generic infrastructure (`NetworkProbe`, `ConfigManager`). 
 
Since `logs`, `reports`, and `config` live under `%LOCALAPPDATA%\DONUT`, an MSI upgrade in
`Program Files` never touches user data.

## 2. Architecture (MVVM)

Every surface renders through data bindings: the machine list is a virtualizing
`ListBox` of `HostViewModel`s, the detail pane and overview strip bind to
`SelectedMachine.*`, and the folders tree, AD finder dropdown, toasts, dialogs,
login window, settings overlay, and shell chrome all bind their own view-models.

### The Layers
1. **Model layer (`src/Models`, `src/Services`, `src/Core`)** — data, business
   logic, and infrastructure.
   - **Models**: data models and pure mappers (e.g. `AppConfig`, `FleetCardStatus`).
   - **Services**: project-specific modules (e.g. `SelfUpdateService`).
   - **Core**: general, reusable modules (e.g. `NetworkProbe`).
2. **View layer (`src/UI/Views`)** — XAML: structure, layout, `DataTemplate`s, and
   bindings. No code-behind.
3. **ViewModel layer (`src/UI/ViewModels`)** — bindable state (`ObservableObject`
   subclasses) + `RelayCommand`s. Calls the pure Model mappers for display decisions,
   so WPF-free logic stays unit-testable.
4. **Presenter layer (`src/UI/Presenters`)** — coordinators/services: load views, own
   background jobs and timers, build the view-models, wire commands, and run the
   imperative shell work.

### The MVVM bases
PowerShell classes cannot declare CLR events, so `INotifyPropertyChanged` cannot be
implemented natively. Two tiny C# bases (`src/Launcher/`, namespace `Donut.Mvvm`,
compiled into `Donut.Launcher` for production and `Add-Type`-compiled by
`Start-Donut.ps1` on the dev path) close the gap:

- **`ObservableObject`** — implements `INotifyPropertyChanged`; PowerShell view-model
  classes inherit it and call `Set(name, value)` (raises change notification only when
  the value actually changes) or `Raise(name)`.
- **`RelayCommand`** — a minimal `ICommand` wrapping a PowerShell scriptblock, so
  buttons/gestures bind to commands instead of `Add_Click` wiring.

### Presenters are coordinators
The `*Presenter` classes keep their original names for continuity, but their role is
**coordinator / UI-service**, not MVP passive-view presenter — they no longer poke
controls. A rename to `*Coordinator`/`*Service` would be cosmetic churn across the UI
layer, so the name is retained by choice (`ToastService` already carries the accurate
suffix). A few surfaces stay deliberately imperative, each the standard MVVM answer:

- **`DialogPresenter`** is a *dialog service* — showing a modal and returning a result
  is inherently imperative; the dialog's *content* binds a `DialogViewModel`.
- **`MainPresenter`** keeps lazy Config construction (the Config view builds on first
  settings-overlay open — a startup-cost win) and the Home fade-in; the shell's
  settings-overlay/chrome *inputs* are bound commands on `MainViewModel`.
- **`ConfigPresenter`** keeps its data-driven form binder: every named control in a
  command's option view maps 1:1 to a dcu-cli arg key, so a typed property per field
  would restate the key list for no behaviour gain.

### Design decisions
`HomePresenter` is the largest coordinator because it owns the `AsyncJob` pump plus
the run/apply flow and the machine list. Three cohesive clusters have been carved off
it — `FinderPresenter` (AD finder + Lens), `InventoryPresenter` (detail panel +
inventory/disk probes), and `ResolutionCoordinator` (the resolve-job lifecycle +
runspace-pool warm) — following a consistent seam:

- **Duck-typed back-ref.** Each coordinator is constructed with a `[object] $Home`
  reference to `HomePresenter` and calls back through it. A *typed* `[HomePresenter]`
  field would create a `using module` import cycle, so the back-ref is intentionally
  `[object]`.
- **Split the gate.** When a cluster is coupled to shared coordination state, only the
  *execution* moves out; the gate stays with its owner. Two cases: the reachability
  check that decides whether to probe a host stays in `HomePresenter.StartInventory`
  while only the probe execution (`RunInventoryProbe`) moved to `InventoryPresenter`;
  and the run/gather queue stays in `HomePresenter` while `ResolutionCoordinator`, once
  a verdict lands, re-issues queued work through the `ReissueAfterResolve` /
  `DropPendingRunOnResolveFailure` seam methods. This keeps the reachability queue and
  the `AsyncJob` pump single-owned by `HomePresenter`.
- **Shared, not owned.** `HostResolver` has call sites across resolution, run, apply,
  and the inventory gate, so `HomePresenter` keeps the single instance and passes it to
  `ResolutionCoordinator` by reference rather than handing over ownership.
- **One cluster at a time.** Each extraction is a cohesive unit with its own test; the
  remainder (pump + run/apply + shell) is the irreducible core and is left intact
  rather than fragmented into further back-ref indirection.

## 3. Key Classes

Many models are deliberately WPF-free **pure mappers/DTOs** (no UI, no I/O) so the
decision/format logic is unit-tested off-domain; a view-model (or coordinator)
consumes the result and exposes it to the bindings. The full structure is in
[`class_diagram.puml`](diagrams/class_diagram.puml).

### Models (`src/Models/`)
| Class | Purpose |
|-------|---------|
| `AppConfig` | Configuration container with defaults, settings merge, and DCU CLI argument building |
| `DeviceContext` | Remote device state: hostname, IP, online status, status message |
| `JobStatus` / `JobKind` (enums) | Job lifecycle state and the kind of remote operation (`Scan`, `UpdateScan`, `UpdateApply`, `Inventory`, `DiskScan`, `Resolve`) |
| `FleetCardStatus` | Pure mapper: a job's (type, status, reboot) → card label, colour key, busy flag |
| `DcuProgress` | Pure parser: a DCU output line → percent complete, plus the scan's milestone step (`N/5` beside the progress bar) |
| `DcuLog` | Pure parser for dcu-cli's `-outputLog`: extracts the authoritative "return code: N" line and classifies it (only {0, 1, 5} are success/reboot; everything else is an error) |
| `RemoteError` (exception hierarchy) | Typed, severity-tagged remote failures: offline / unresolvable / RPC blocked / DCU not installed / launch fault / **connection lost** (psexec transport codes 233, 64, ...) / **timed out** (watchdog); `RemoteFailure` re-derives the reason from a worker message that crossed the runspace boundary |
| `ScanCacheDecision` | Pure rule: is a host's last scan still fresh enough to reuse (24h)? |
| `MachineInventory` / `InventoryFormat` | Per-machine probe DTO (model, service tag, battery health, disk, uptime) + label formatting |
| `DiskUsage*` (`FolderUsage`, `DiskUsageReport`, `WizTreeCsv`, `DiskUsageTree`, `FolderTreeNode`, `DiskUsageFormat`) | "Biggest folders on C:" DTO + WizTree CSV parse + path-containment tree builder + size formatting |
| `AdSearchResult` / `AdFilter` | AD finder DTO + pure LDAP-filter construction, escaping, and lock/disable decode |
| `PersonLens` / `LensDevice` / `LensBitLockerKey` / `LensFormat` | User-Lens DTOs (a person's directory facts + their devices with OS / last domain logon / BitLocker keys) parsed from the lookup's JSON bundle, plus pure "last seen" formatting |
| `RecentConnection` / `RecentConnectionsStore` | Persisted "recent machines" backing the Home list (status, counts, cached inventory + disk usage) |
| `DeviceFlowDecision` (+ `PollOutcome`) | Pure mapper: a GitHub device-flow poll result → continue / authorized / slow-down / fail |

### Core (`src/Core/`)
| Class | Purpose |
|-------|---------|
| `ConfigManager` | Load/save JSON config, directory initialization |
| `NetworkProbe` | Domain-controller-authoritative DNS resolution (cached DC discovery + `Resolve-DnsName -Server`, fail-hard), reverse-DNS validation, RPC/online checks |
| `AsyncJob` | Runspace-based async job wrapper with PowerShell execution |
| `RunspaceManager` | Static RunspacePool management for parallel execution |
| `HostListSource` | Resolves and reads the bundled host list (e.g. `WSID.txt`) |
| `TimeFormat` | Pure "relative time" formatter (`2m ago`) |
| `LogService` | Thread-safe leveled logging (`[INFO]/[WARN]/[ERROR]/[DEBUG]`) to file, with exception + structured helpers and a `NullLogService` no-op |
| `DispatcherWatchdog` | **Diagnostic (temporary):** a `DispatcherTimer` that logs when the UI thread stalls past a threshold, to pin the intermittent disk-scan-mid-scan freeze (suspected CLR loader-lock contention). Paired with per-phase timing in `ExecutionService.RunDiskScanPhase`; both are removed once the freeze is pinned |

### Services (`src/Services/`)
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
| `ActiveDirectoryService` | Live multi-forest AD search (computers + users) and account unlock |
| `PersonLensService` | User Lens: resolves a person to their directory facts + SCCM devices + BitLocker keys, run **de-elevated as the logged-on user** (see [De-elevating the user Lens](#de-elevating-the-user-lens)); parses the worker's JSON bundle (the de-elevation is an overridable seam) |
| `DriverMatchingService` | Brand-based driver/update matching with category support |
| `SystemInfoService` | Local machine facts (identity, domain, battery) for the title bar |
| `SelfUpdateService` | GitHub releases, token management, MSI verification |
| `ResourceService` | XAML resource dictionary loading |

### ViewModels (`src/UI/ViewModels/`)
All inherit the C# `Donut.Mvvm.ObservableObject` base unless noted; commands are
`RelayCommand`s wired by the owning presenter.

| Class | Purpose |
|-------|---------|
| `HomeViewModel` | The Home page: `Machines` (bound to the virtualizing ListBox), `SelectedMachine`, and the AD finder's `SearchResults` |
| `HostViewModel` | One machine row + the detail pane it mirrors: status dot/chip/progress/step text, overview-strip facts, probed subtitle, folders tree, Run/Gather commands |
| `FolderNodeViewModel` | Display-ready largest-folders tree node (pure, computed per report) |
| `SearchRowViewModel` | AD finder dropdown row — section header or result, with Pick/Unlock commands (pure) |
| `PersonLensViewModel` / `LensDeviceViewModel` | The user Lens shown in the detail pane: person fields + a device collection, each device with a Reveal-BitLocker toggle and an Add-to-machine-list command |
| `ConfigViewModel` | Config chrome (SaveCommand); the option forms stay on the presenter's data-driven binder by design |
| `ToastViewModel` | One toast card (title/message/accent/IsClosing for the exit animation) |
| `DialogViewModel` | One modal dialog's content (title/message/list/buttons + verdict commands) |
| `LoginViewModel` | Login window content (output text + AuthCommand) |
| `MainViewModel` | Shell: OpenSettings/CloseSettings commands, window chrome commands, IsSettingsOpen |

### Presenters (`src/UI/Presenters/`)
Coordinators/services: they own the engine objects and build/wire the view-models. See
[Design decisions](#design-decisions) for the back-ref seam that links them, and
[`component_diagram.puml`](diagrams/component_diagram.puml) for the wiring.

| Class | Purpose |
|-------|---------|
| `MainPresenter` | Composition root: main window, lazy Config construction, the settings overlay, shell command targets |
| `AsyncJobPresenter` | Base class: pumps queued `AsyncJob`s on a `DispatcherTimer` (poll → settle) |
| `HomePresenter` | Owns the `AsyncJob` pump, the add/scan/apply run flow, the machine rows/list, and housekeeping. Delegates the detail panel to `InventoryPresenter`, resolve/warm to `ResolutionCoordinator`, and the search-bar finder + Lens to `FinderPresenter` |
| `InventoryPresenter` | The per-machine detail panel: header + overview render, the job log, the CIM inventory probe and WizTree storage scan (execution + completion), and machine selection. Its `Inventory` / `DiskScan` jobs are drained by `HomePresenter`'s pump and forwarded back to it |
| `ResolutionCoordinator` | The `Resolve` job lifecycle and runspace-pool warm: start-early IP resolution via the shared `HostResolver`, verdict caching, and DC discovery/persist. When a verdict lands it re-issues queued runs/gathers through `HomePresenter`'s seam methods |
| `FinderPresenter` | The search bar's live multi-forest AD finder (debounced per-forest fan-out + inline unlock) and the **user Lens** (agent lookup, partial streaming, in-memory TTL cache); raw pool jobs polled on `DispatcherTimer`s. Calls back into `HomePresenter`'s machine seams (`PrefetchIp`, `EnsureRow`, `StartInventory`, `MoveRowToTop`, `UpdateEmptyHint`) via the duck-typed back-ref |
| `ConfigPresenter` | Hosted in the settings overlay: command selection, the data-driven option-form binder, args persistence; toasts + closes the overlay on save |
| `LoginPresenter` | GitHub Device Flow: poll timer + modal lifecycle behind `LoginViewModel` |
| `UpdatePresenter` | Self-update check and prompt |
| `DialogPresenter` | Dialog service: shows the modal `DialogWindow`, returns the verdict |
| `ToastService` | Enqueues `ToastViewModel`s + owns the auto-dismiss/exit-animation timers |

## 4. Runtime Flows

The sequence and activity diagrams under [`docs/diagrams/`](diagrams/README.md) trace
the load-bearing flows end to end:

| Flow | Diagram |
|------|---------|
| Scan a machine (async, non-blocking) | [`scan_sequence_diagram.puml`](diagrams/scan_sequence_diagram.puml) |
| Apply updates (scan reuse + confirm) | [`applyUpdates_sequence_diagram.puml`](diagrams/applyUpdates_sequence_diagram.puml) |
| Remote worker flow (in a pool runspace) | [`activity_diagram.puml`](diagrams/activity_diagram.puml) |
| Detail: inventory prefetch + storage scan | [`inventory_sequence_diagram.puml`](diagrams/inventory_sequence_diagram.puml) |
| Live AD finder + unlock | [`ad_finder_sequence_diagram.puml`](diagrams/ad_finder_sequence_diagram.puml) |
| User Lens (de-elevated agent) | [`lens_lookup_sequence_diagram.puml`](diagrams/lens_lookup_sequence_diagram.puml) |
| Self-update (device flow + MSI) | [`update_sequence_diagram.puml`](diagrams/update_sequence_diagram.puml) |

## 5. Implementation Notes

How the design handles the constraints of remote execution, threading, and packaging.

### Parallel Execution (Runspaces)
The original tool used PowerShell runspaces for parallel execution; DONUT keeps that
model.

- **Classes in runspaces:** PowerShell classes are not automatically available in new
  runspaces, so the required class modules (`Models`, `Services`) are explicitly
  loaded into each runspace before execution.
- **Thread safety:** `LogService` is thread-safe. Work is fed back to the UI through a
  thread-safe state/queue that a `DispatcherTimer` polls on the UI thread — **not** by
  returning results (which only surface when the runspace completes) — so the "live
  feed" updates in real time.

### Remote Execution (PsExec)
`PsExec` is the primary execution engine over native PowerShell Remoting: it runs over
SMB (port 445), avoids WinRM/TrustedHosts configuration, and natively supports
`SYSTEM` execution.

- **Encapsulation:** `ExecutionService` wraps the `PsExec` calls; `NetworkProbe`
  handles the pre-run checks (DNS, reverse-DNS, RPC), isolating network logic from
  execution.
- **Remote file handling:** UNC copy of the remote `outputLog` and `report` files,
  per-host temp logs, and report-XML consolidation before writing local logs; the
  `DellCommandUpdate` service is pre-stopped before running DCU.
- **DCU CLI syntax:** `dcu-cli.exe /<command> -option=value` (not `/key`); booleans as
  `-silent` or `-reboot=enable`. The remote work dir is `C:\temp\DONUT`.
- **Exit codes (see `DcuLog`):** `0` is the only unconditional success; `1`/`5` mean
  "completed, reboot required" (flagged, not an error); everything else is a real
  failure — including the small codes (`2` unknown, `3` not a Dell system, `4` not
  admin, `6` another DCU instance, `7`/`8` unsupported).
- **PsExec arguments:** `-s` (SYSTEM), `-h` (elevated), `-accepteula`, with
  `pwsh -NoProfile -NonInteractive -c` for clean remote execution.
- **Headless launch:** psexec is started through `ProcessStartInfo` with
  `CreateNoWindow` (a *hidden* console), not `Start-Process -NoNewWindow`. DONUT is a
  window-subsystem GUI with no console of its own, so `-NoNewWindow` makes the OS spawn
  a **visible** console per psexec; several at once sit in front of the WPF window and
  read as a frozen UI. A hidden console leaves psexec a *real* console — so its stdout
  is **not** redirected (redirecting it removed the console and caused remote
  `0xC0000142` init failures) — with no window. `ExecutionService.StartPsExecHidden`
  is the shared launcher.

### De-elevating the user Lens
DONUT runs **elevated as an admin account** (required for the psexec/CIM remote work),
but the user Lens data is only readable by the operator's **regular account**: the
person→device mapping and hardware inventory come from **SCCM** (its AdminService is
RBAC-scoped to the regular account, not the admin one), and BitLocker recovery keys sit
in **AD** under the computer object. Elevating does not grant the regular account's
rights — a separate identity means a separate process.

**A persistent de-elevated agent:**
- A single **`LensAgent.ps1`** runs de-elevated as the **interactive user** for the
  app's whole lifetime, started via a **scheduled task** (`LogonType Interactive` = the
  logged-on token, *no password*; `RunLevel Limited` = medium integrity; action wrapped
  in `conhost.exe --headless` so no console window ever flashes). `Shell.Application`
  was tried and rejected — it only de-elevates within the *same* user.
  `FinderPresenter.WarmLens` starts it on the pool at app startup (fire-and-forget, in
  parallel with the pool/AD warm), so as its own process it pre-warms its AD/SCCM
  libraries while DONUT is still booting — and even the **first** pick skips the
  per-lookup task registration + `pwsh` cold start (~2-4 s) the previous one-shot-task
  design paid every time.
- `PersonLensService` is the agent's **supervisor + client**. `EnsureAgent`
  (mutex-guarded so concurrent pool runspaces can't double-start) treats a
  `heartbeat.txt` older than 15 s as a dead agent and re-registers the task;
  `RunLookupJson` then drives one lookup over the exchange. The agent beats from a
  **background thread** (not the serve loop), so a lookup in flight — which blocks the
  serve loop for tens of seconds — never lets the beat go stale and get the busy agent
  torn down mid-lookup. It self-exits when DONUT's process dies (a `-ParentPid`
  watchdog), when a `stop.flag` appears, or when the exchange dir is purged.
- The agent reads AD forest-wide via the **Global Catalog** (`GC://...`, then binds
  each object's home domain) and SCCM via the **AdminService REST** endpoint
  (`-UseDefaultCredentials`, no ConfigMgr module/PSDrive). The parse
  (`PersonLens.FromJson`) is pure/tested; the agent/task I/O is the overridable
  `RunLookupJson` seam. The `%5C` (backslash) gotcha in the SCCM query is avoided by
  filtering on the forest-unique SAM (`endswith`) and exact-matching client-side.

**The exchange protocol** (fixed `%ProgramData%\DONUT\lens-agent` dir): the parent drops
`request-<id>.bin`; the agent answers `partial-<id>-1.bin` (directory facts),
`partial-<id>-2.bin` (name-only device rows) and `result-<id>.bin`. Each side deletes
what it consumed; the agent sweeps anything older than 10 minutes.

**Securing the exchange (the bundle holds BitLocker recovery keys):**
- The exchange folder's inherited ACL is **stripped** (ProgramData grants all local
  users read) down to SYSTEM / Administrators / the interactive user.
- Every payload is **AES-256-CBC encrypted** with a **per-session key** minted when the
  agent starts (`key.bin`, 32-byte key + 16-byte IV;
  `PersonLensService.ProtectText`/`UnprotectText`/`WriteEncrypted` are the unit-tested
  twins of the agent's inline crypto). Nothing touches disk in the clear. The ACL-locked
  dir is the real boundary; the key is defense-in-depth.
- On window close the parent drops `stop.flag`, **stops + unregisters** the task, and
  deletes every `lens-*` dir. The per-person UI cache is **memory-only**
  (`FinderPresenter.LensCache`, 15-min TTL), so it dies with the process.

**Keeping it fast:** the agent is already warm (no task/`pwsh`/library cold start per
pick); one SCCM call total (the affinity query, person → WSIDs) with everything
per-device read from the computer's AD object; the affinity query runs on a thread job
in parallel with the AD user read; and the agent streams **sequential partial bundles**
(directory facts, then name-only device rows, then the filled detail) so the UI paints
progressively. The AdminService `/wmi` route's OData translator rejects richer filters
(`or`, backslashes) with **404**, so per-device SCCM detail queries were dropped rather
than fought.

### UI & Threading
WPF UI updates must happen on the UI thread, and past freezes came from background
threads touching the UI directly.

- **Polling, not marshalling:** state changes (`ScanStarted`, `ScanCompleted`, log
  lines) update a thread-safe state object/queue; a single `DispatcherTimer` drains it
  on the UI thread in batches. DONUT does **not** use `Dispatcher.Invoke` /
  `BeginInvoke` for this — flooding the dispatcher with per-event invocations was a
  freeze source.
- **ApplyUpdates two-phase flow:** temporary scan config → run scan → copy report XML →
  gather remote driver/app data via PsExec → brand-based matching → per-host
  confirmation popup (skip apply if not confirmed) → skip apply when no updates → copy
  the updates list to the clipboard.
- **Manual reboot detection:** parse log lines for reboot-required vs auto-reboot;
  surface a completion popup listing machines needing manual reboot. Pre-seed the
  manual-reboot list when config disables automatic reboot (`reboot`/`forceRestart`).
- **Multi-device safety prompt:** if ApplyUpdates is enabled and multiple hosts are
  queued, show a single confirmation listing all targets before enqueueing runspaces.

### Configuration & Persistence
- **JSON config:** `config.json` (migrated from the old `config.txt`); `wsid.txt` and
  `config.json` live under `%LOCALAPPDATA%\DONUT\` so they persist across updates.
  `ConfigManager` reads/writes both, prioritizing the `%LOCALAPPDATA%` copy.
- **Structure:** `activeCommand` (`scan` or `applyUpdates`), a global `throttleLimit`,
  and a `commands` dictionary of `args` hashtables. `AppConfig` merges user settings
  with `[AppConfig]::Defaults` so all expected keys exist.
- **`AppConfig.BuildDcuArgs()`** generates DCU CLI format: `-option=value` syntax,
  boolean `true` → `-silent` / `-reboot=enable`, `false` → omitted (or `=disable` if
  explicit), empty strings omitted, values with spaces quoted.

<details>
<summary>Example <code>config.json</code></summary>

```json
{
  "activeCommand": "scan",
  "throttleLimit": 5,
  "commands": {
    "scan": {
      "args": {
        "silent": false,
        "report": "",
        "outputLog": "",
        "updateSeverity": "",
        "updateType": "",
        "updateDeviceCategory": "",
        "catalogLocation": ""
      }
    },
    "applyUpdates": {
      "args": {
        "silent": false,
        "reboot": false,
        "autoSuspendBitLocker": true,
        "forceupdate": false,
        "outputLog": "",
        "updateSeverity": "",
        "updateType": "",
        "updateDeviceCategory": "",
        "catalogLocation": ""
      }
    }
  }
}
```

</details>

<details>
<summary>DCU CLI options reference</summary>

Based on the [Dell Command Update CLI Reference](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-update-cli-commands):

| Option | Commands | Values | Description |
|--------|----------|--------|-------------|
| `silent` | scan, applyUpdates | (flag) | Hide status/progress |
| `report` | scan | path | XML report location |
| `outputLog` | scan, applyUpdates | path | Log file path |
| `reboot` | applyUpdates | enable/disable | Auto-reboot after updates |
| `autoSuspendBitLocker` | applyUpdates | enable/disable | Suspend BitLocker for BIOS |
| `forceupdate` | applyUpdates | enable/disable | Override pause during calls |
| `updateSeverity` | scan, applyUpdates | security,critical,recommended,optional | Filter by severity |
| `updateType` | scan, applyUpdates | bios,firmware,driver,application,others | Filter by type |
| `updateDeviceCategory` | scan, applyUpdates | audio,video,network,storage,input,chipset,others | Filter by category |
| `catalogLocation` | scan, applyUpdates | path | Custom catalog path |

</details>

### PowerShell Constraints to Retain
- **Absolute script paths in runspaces:** child runspaces must receive absolute script
  paths because `AddScript` rejects relative paths in the packaged build.
- **Window chrome for resize:** XAML `WindowChrome` with `AllowsTransparency="False"`,
  `WindowStyle="None"`, `ResizeMode="CanResize"`, and
  `WindowChrome.ResizeBorderThickness="6"` keeps edge/corner resize without any P/Invoke.
- **`InstallWorker.ps1` stays a standalone script** (not a class) in `src/Scripts/` so
  `SelfUpdateService` can copy it to `%LOCALAPPDATA%\DONUT` and run it independently
  for updates/rollbacks; the copy is hash-gated (SHA-256) to avoid needless writes, and
  Device Flow tokens are DPAPI-protected (CurrentUser).

## 6. Testing

The core principle is **dependency injection**: a class whose only job is to touch the
network or file system is wrapped so tests can substitute a fake.

```powershell
# Wrapper (src/Core/NetworkProbe.psm1) — the only thing that touches the network
class NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.Dns]::GetHostAddresses($hostname)[0]
    }
}

# Service takes the probe in its constructor
class RemoteJobService {
    hidden $NetworkProbe
    RemoteJobService($probe) { $this.NetworkProbe = $probe }
}

# Test substitutes a mock
class MockNetworkProbe : NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.IPAddress]::Parse("192.168.1.100")
    }
}
```

| Component | What to test | How to mock |
| :--- | :--- | :--- |
| **Models** | Properties, simple validation, pure mappers/parsers | No mocking needed |
| **Services** | Logic, error handling, orchestration | Mock `NetworkProbe`, file system, PsExec wrapper |
| **Presenters** | UI flow (did clicking Scan call the service?) | Fake the service + a duck-typed `$Home` back-ref |
| **Core** | The actual .NET/exe calls | Don't unit test — use Integration tests |

- **Unit (`tests/Unit`):** config parse/build, service logic with mocks (scan/apply
  two-phase, driver matching, confirmation triggers), self-update token/decision logic,
  the presenter coordinators (e.g. `InventoryPresenter.Tests.ps1`,
  `ResolutionCoordinator.Tests.ps1`) with faked services and a duck-typed `$Home`
  back-ref.
- **Integration (`tests/Integration`):** remote paths (DNS failure, reverse-DNS
  mismatch, RPC 1722) against a mock/loopback target with temp UNC folders to verify
  log/report copy; the ApplyUpdates flow (confirmation/skip, clipboard list); the
  updater flow (SHA-256 verify, HTML/SSO rejection, rollback, hash-gated worker copy).

## 7. Code Coverage

Generate a visual HTML coverage report from the project root:

```powershell
tests/Generate-CoverageReport.ps1
```

It runs the `tests/Unit` suite, emits `coverage.xml` (JaCoCo format), and converts it
into an HTML report under `CoverageReport/` (open `CoverageReport/index.html`).

The HTML generation is powered by
[JaCoCo-XML-to-HTML-PowerShell](https://github.com/constup/JaCoCo-XML-to-HTML-PowerShell)
by [constup](https://github.com/constup) — coverage reports in pure PowerShell, no
external .NET tools or licenses.
