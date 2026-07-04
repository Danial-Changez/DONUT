<h1> DONUT Refactoring Proposal </h1>

This document serves as the proposal/guide for refactoring the DONUT project from a script-based architecture to an OOP structure. There is no support for this implementation, and is being refactored to test what I have learnt.

<h2> Table of Contents </h2>

- [1. Directory Structure](#1-directory-structure)
  - [Key Changes](#key-changes)
- [2. Architecture: MVP → MVVM](#2-architecture-mvp--mvvm)
  - [Why MVP first?](#why-mvp-first)
  - [The MVVM migration](#the-mvvm-migration)
  - [The Layers](#the-layers)
  - [Key Classes](#key-classes)
    - [Models (`src/Models/`)](#models-srcmodels)
    - [Core (`src/Core/`)](#core-srccore)
    - [Services (`src/Services/`)](#services-srcservices)
    - [ViewModels (`src/UI/ViewModels/`)](#viewmodels-srcuiviewmodels)
    - [Presenters (`src/UI/Presenters/`)](#presenters-srcuipresenters)
- [4. Implementation Considerations](#4-implementation-considerations)
  - [Parallel Execution (Runspaces)](#parallel-execution-runspaces)
  - [Remote Execution (PsExec)](#remote-execution-psexec)
  - [The `InstallWorker.ps1` Script](#the-installworkerps1-script)
  - [Packaging \& Deployment (Visual Studio)](#packaging--deployment-visual-studio)
  - [UI \& Threading](#ui--threading)
  - [Configuration \& Persistence](#configuration--persistence)
    - [Example `config.json`](#example-configjson)
    - [DCU CLI Options Reference](#dcu-cli-options-reference)
  - [PowerShell Constraints to Retain](#powershell-constraints-to-retain)
- [5. Testing Strategy](#5-testing-strategy)
  - [The Problem: Side Effects](#the-problem-side-effects)
  - [The Solution: The Wrapper Pattern](#the-solution-the-wrapper-pattern)
    - [1. The Wrapper Class (`src/Core/NetworkProbe.psm1`)](#1-the-wrapper-class-srccorenetworkprobepsm1)
    - [2. The Service Class (`src/Services/RemoteServices.psm1`)](#2-the-service-class-srcservicesremoteservicespsm1)
    - [3. The Pester Test (`tests/Unit/RemoteServices.Tests.ps1`)](#3-the-pester-test-testsunitremoteservicestestsps1)
  - [Summary of What to Test](#summary-of-what-to-test)
  - [Test Structure](#test-structure)
- [6. Code Coverage](#6-code-coverage)
  - [Generating the Report](#generating-the-report)
  - [Viewing the Report](#viewing-the-report)
  - [Credits](#credits)


## 1. Directory Structure

The new structure emphasizes testability and a layered UI architecture (refactored to
MVP first, since migrated to MVVM — see section 2).

```text
root/
├── assets/                 <-- Assets
│   ├── Images/
│   └── Screenshots/
├── bin/                    <-- Binaries/Dependencies
├── docs/                   <-- Documentation
├── src/                    <-- Source Code
│   ├── Core/               <-- Base Classes, Interfaces, Enums (Infrastructure)
│   ├── Models/             <-- Data Classes (DTOs)
│   ├── Services/           <-- Business Logic
│   ├── Scripts/            <-- Standalone scripts
│   ├── UI/                 <-- UI Layer
│   │   ├── Views/          <-- XAML files (The View: templates + bindings)
│   │   ├── Styles/         <-- XAML styles
│   │   ├── ViewModels/     <-- Bindable state + commands (The ViewModel)
│   │   ├── Presenters/     <-- Coordinators / UI services (jobs, timers, dialogs)
│   └── Launcher/           <-- C# Launcher Project (+ Donut.Mvvm base types)
├── tests/                  <-- Pester Tests
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

### Key Changes

1.  **`src/Models` & `src/Services` & `src/Core`**: Explicit separation of concerns.
    *   **Models**: Pure data structures (DTOs).
    *   **Services**: Business logic specific to DONUT.
    *   **Core**: Generic infrastructure and tools (NetworkProbe, ConfigManager).
2.  **`src/Scripts`**: Contains the bootstrap script (`DonutApp.ps1`) and standalone workers.
3.  **`assets`**: Cleans up the root by grouping `Images` and `Screenshots`.
4.  **`tests`**: Adds a dedicated location for Pester tests.

**Note:** For more changes, please refer to the [PUML diagrams](diagrams).

---

## 2. Architecture: MVP → MVVM

The project was first refactored to the **Passive View** variant of the MVP pattern,
then migrated top-down to **MVVM** once the layers had settled. The engine —
`Models/`, `Services/`, `Core/`, and the `AsyncJob` polling pump — was untouched by
that migration; only how a drained result reaches the screen changed (set a
view-model property instead of poking a control).

### Why MVP first?
*   **Migration:** MVP is similar to the original scripts. It allowed logic to be moved from scripts to classes with minimal rewriting.
*   **PowerShell Constraints:** PowerShell classes cannot declare CLR events, so `INotifyPropertyChanged` cannot be implemented natively. MVP sidestepped this by having the Presenter directly manipulate the View.

### The MVVM migration
The event constraint is solved by two tiny C# bases (`src/Launcher/`, namespace
`Donut.Mvvm`), compiled into `Donut.Launcher` for production and `Add-Type`-compiled
by `Start-Donut.ps1` on the dev path:

*   **`ObservableObject`** — implements `INotifyPropertyChanged`; PowerShell
    view-model classes inherit it and call `Set(name, value)` (raises change
    notification only when the value actually changes) or `Raise(name)`.
*   **`RelayCommand`** — a minimal `ICommand` wrapping a PowerShell scriptblock, so
    buttons/gestures bind to commands instead of `Add_Click` wiring.

Every surface renders through bindings: the machine list is a virtualizing `ListBox`
of `HostViewModel`s, the detail pane and overview strip bind to `SelectedMachine.*`,
and the folders tree, AD finder dropdown, Logs tabs, toasts, dialogs, login window,
and shell chrome all bind their own view-models. Presenters were **kept as
coordinators/services**, not deleted: they own the services, the `AsyncJob` queue,
the `DispatcherTimer`s, and the modal lifecycle, and they build the view-models and
wire their commands.

> **On the `*Presenter` name.** The classes keep their original names for continuity,
> but post-MVVM their role is **coordinator / UI-service**, not MVP passive-view
> presenter — they no longer poke controls. A rename to `*Coordinator`/`*Service` would
> be purely cosmetic churn across the UI layer (and half-doing it, e.g. only
> `DialogPresenter`, would read worse than leaving them), so the name is retained by
> choice. `ToastService` is the one already carrying the accurate suffix.

Deliberately still imperative (each is the standard MVVM answer, not a leftover):

*   **`DialogPresenter`** stays a *dialog service* — showing a modal and returning a
    result is inherently imperative; the dialog's *content* binds a `DialogViewModel`.
*   **`MainPresenter`** keeps lazy page construction (Config/Logs are built on first
    navigation — a startup-cost win) and the rail width/label animations; the shell's
    nav/rail/chrome *inputs* are bound commands on `MainViewModel`.
*   **`ConfigPresenter`** keeps its data-driven form binder: every named control in a
    command's option view maps 1:1 to a dcu-cli arg key, so a typed property per
    field would restate the key list for no behaviour gain.

### The Layers
1.  **Model Layer (`src/Models`, `src/Services`, `src/Core`)**:
    *   Represents the data, business logic, and infrastructure.
    *   **Models**: The data models and pure mappers (e.g., `AppConfig`, `FleetStatus`).
    *   **Services**: Project-specific modules (e.g., `SelfUpdateService`).
    *   **Core**: General (reusable) modules (e.g., `NetworkProbe`).
2.  **View Layer (`src/UI/Views`)**:
    *   XAML files: structure, layout, `DataTemplate`s, and bindings. No code-behind.
3.  **ViewModel Layer (`src/UI/ViewModels`)**:
    *   Bindable state (`ObservableObject` subclasses) + `RelayCommand`s.
    *   Calls the pure Model mappers for its display decisions; WPF-free logic stays
        unit-testable.
4.  **Presenter Layer (`src/UI/Presenters`)**:
    *   Coordinators/services: load views, own background jobs and timers, build the
        view-models, wire commands, and run the imperative shell work listed above.

### Key Classes

Many models are deliberately WPF-free **pure mappers/DTOs** (no UI, no I/O) so the
decision/format logic is unit-tested off-domain; a view-model (or coordinator)
consumes the result and exposes it to the bindings.

#### Models (`src/Models/`)
| Class | Purpose |
|-------|---------|
| `AppConfig` | Configuration container with defaults, settings merge, and DCU CLI argument building |
| `DeviceContext` | Remote device state: hostname, IP, online status, status message |
| `JobStatus` / `JobKind` (enums) | Job lifecycle state and the kind of remote operation (`Scan`, `UpdateScan`, `UpdateApply`, `Inventory`, `DiskScan`, `Resolve`) |
| `FleetStatus` | Pure mapper: a job's (type, status, reboot) → card label, colour key, busy flag |
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

#### Core (`src/Core/`)
| Class | Purpose |
|-------|---------|
| `ConfigManager` | Load/save JSON config, directory initialization |
| `NetworkProbe` | Domain-controller-authoritative DNS resolution (cached DC discovery + `Resolve-DnsName -Server`, fail-hard), reverse-DNS validation, RPC/online checks |
| `AsyncJob` | Runspace-based async job wrapper with PowerShell execution |
| `RunspaceManager` | Static RunspacePool management for parallel execution |
| `HostListSource` | Resolves and reads the bundled host list (e.g. `WSID.txt`) |
| `TimeFormat` | Pure "relative time" formatter (`2m ago`) |
| `LogService` | Thread-safe leveled logging (`[INFO]/[WARN]/[ERROR]/[DEBUG]`) to file, with exception + structured helpers and a `NullLogService` no-op |

#### Services (`src/Services/`)
All remote services subclass `RemoteJobService` (shared worker-arg
building); they only **prepare/parse** off the UI thread — the worker does the network I/O.

| Class | Purpose |
|-------|---------|
| `ExecutionService` | Remote PsExec execution, DCU CLI invocation, per-phase dispatch (resolve/scan/apply/inventory/disk), artifact copy |
| `ScanService` | Prepare scan operations |
| `RemoteUpdateService` | Prepare update scan/apply with driver matching; parse + count the update report |
| `InventoryService` | Prepare + parse the per-machine CIM inventory probe |
| `DiskUsageService` | Prepare + parse the on-demand WizTree "biggest folders" scan |
| `HostResolver` | Start-early IP-resolution cache (warm the active DC, prefetch on select) |
| `ActiveDirectoryService` | Live multi-forest AD search (computers + users) and account unlock |
| `PersonLensService` | User Lens: resolves a person to their directory facts + SCCM devices + BitLocker keys, run **de-elevated as the logged-on user** (see [De-elevating for SCCM/BitLocker](#de-elevating-the-user-lens)); parses the worker's JSON bundle (the de-elevation is an overridable seam) |
| `DriverMatchingService` | Brand-based driver/update matching with category support |
| `SystemInfoService` | Local machine facts (identity, domain, battery) for the title bar |
| `SelfUpdateService` | GitHub releases, token management, MSI verification |
| `ResourceService` | XAML resource dictionary loading |

#### ViewModels (`src/UI/ViewModels/`)
All inherit the C# `Donut.Mvvm.ObservableObject` base unless noted; commands are
`RelayCommand`s wired by the owning presenter.

| Class | Purpose |
|-------|---------|
| `HomeViewModel` | The Home page: `Machines` (bound to the virtualizing ListBox), `SelectedMachine`, and the AD finder's `SearchResults` |
| `HostViewModel` | One machine row + the detail pane it mirrors: status dot/chip/progress/step text, overview-strip facts, probed subtitle, folders tree, Run/Gather commands |
| `FolderNodeViewModel` | Display-ready largest-folders tree node (pure, computed per report) |
| `SearchRowViewModel` | AD finder dropdown row — section header or result, with Pick/Unlock commands (pure) |
| `PersonLensViewModel` / `LensDeviceViewModel` | The user Lens shown in the detail pane: person fields + a device collection, each device with a Reveal-BitLocker toggle and an Add-to-machine-list command |
| `ConfigViewModel` | Config page chrome (SaveCommand); the option forms stay on the presenter's data-driven binder by design |
| `LogsViewModel` / `LogTabViewModel` | Logs page: tab collection + per-tab text with tail-truncation ("Load full file") state |
| `ToastViewModel` | One toast card (title/message/accent/IsClosing for the exit animation) |
| `DialogViewModel` | One modal dialog's content (title/message/list/buttons + verdict commands) |
| `LoginViewModel` | Login window content (output text + AuthCommand) |
| `MainViewModel` | Shell: NavigateCommand, rail toggle, window chrome commands, ActivePage/IsRailCollapsed |

#### Presenters (`src/UI/Presenters/`)
Coordinators/services after the MVVM migration: they own the engine objects and
build/wire the view-models (see [The MVVM migration](#the-mvvm-migration)).

| Class | Purpose |
|-------|---------|
| `MainPresenter` | Composition root: main window, lazy page construction, rail animation, shell command targets |
| `AsyncJobPresenter` | Base class: pumps queued `AsyncJob`s on a `DispatcherTimer` (poll → settle) |
| `HomePresenter` | Add/scan/apply, per-machine detail (inventory + storage scan), live AD finder, job management; sets `HostViewModel` state per pump tick. Also drives the **user Lens**: picking a user runs the de-elevated lookup on the pool, populates the `PersonLensViewModel`, and switches the detail pane to Person mode |
| `ConfigPresenter` | Command selection, the data-driven option-form binder, args persistence |
| `LogsPresenter` | Log file I/O (enumerate, tail-read, load-full, clear) behind `LogsViewModel` |
| `LoginPresenter` | GitHub Device Flow: poll timer + modal lifecycle behind `LoginViewModel` |
| `UpdatePresenter` | Self-update check and prompt |
| `DialogPresenter` | Dialog service: shows the modal `DialogWindow`, returns the verdict |
| `ToastService` | Enqueues `ToastViewModel`s + owns the auto-dismiss/exit-animation timers |

---

## 4. Implementation Considerations

This section discusses how the refactor addresses the design choices and limitations identified in the original project.

### Parallel Execution (Runspaces)
**Challenge:** The original project uses PowerShell Runspaces for parallel execution.

**Refactor Strategy:**
- **Classes in Runspaces:** PowerShell classes are not automatically available in new runspaces. The `MainController` must explicitly load the required class modules (`Models`, `Services`) into each runspace before execution.
- **Thread Safety:** The `LogService` must be thread-safe. We will use a **Synchronized Wrapper** pattern (similar to the existing `$script:SyncUI` implementation).
    - The `MainController` creates a thread-safe collection (i.e. `[System.Collections.Concurrent.ConcurrentQueue[string]]`).
    - This collection is passed into the Runspace and injected into `RemoteJobService`.
    - The Service writes logs to this queue.
    - The `MainController` polls this queue on the UI thread (via a DispatcherTimer) to update the View.
    - *Why not return results?* Returning results only happens when the runspace completes. We need real-time feedback for the "Live Feed" feature.

### Remote Execution (PsExec)
**Challenge:** Reliance on `PsExec` and handling specific error codes (RPC, DNS).

*Rationale:* `PsExec` is retained as the primary execution engine because it offers superior reliability compared to native PowerShell Remoting (`Invoke-Command`). It operates over SMB (port 445), avoiding WinRM configuration issues (e.g., managing TrustedHosts lists), and natively supports execution as the `SYSTEM` account.

**Refactor Strategy:**
- **Encapsulation:** The `ExecutionService` will wrap the `PsExec` calls.
- **Validation:** The `NetworkProbe` class will handle the pre-run checks (DNS, Reverse-DNS, RPC) currently in `remoteDCU.ps1`. This isolates the network logic from the execution logic.
- **Maintain remote file handling:** Preserve UNC copy of remote `outputLog` and `report` files, including per-host temporary logs and report XML consolidation before writing to local logs. Keep the pre-stop of `DellCommandUpdate` before running DCU.
- **DCU CLI Syntax:** Use proper Dell Command Update CLI format:
  - Command syntax: `dcu-cli.exe /<command> -option1=value1 -option2=value2`
  - Arguments use `-key=value` format (not `/key`)
  - Boolean flags: `-silent` or `-reboot=enable`
- **Remote Directory Setup:** Create `C:\temp\DONUT` on remote host before execution
- **Exit Code Handling:** DCU CLI returns specific exit codes:
  - `0`: Success
  - `1`: Reboot required (logged, not treated as error)
  - `2-5`: Various success states
  - `500+`: Errors (throws exception)
- **PsExec Arguments:** Use `-s` (SYSTEM), `-h` (elevated), `-accepteula`, with `pwsh -NoProfile -NonInteractive -c` for cleaner remote execution

### De-elevating the user Lens
**Challenge:** DONUT runs **elevated as an admin account** (required for the psexec/CIM
remote work), but the user Lens data is only readable by the operator's **regular account**:
the person→device mapping and hardware inventory come from **SCCM** (its AdminService is
RBAC-scoped to the regular account, not the admin one), and BitLocker recovery keys sit in
**AD** under the computer object. Elevating does not grant the regular account's rights — a
separate identity means a separate process.

**Strategy — run the lookup de-elevated as the logged-on user:**
- `LensLookupWorker.ps1` runs on the pool (as admin) and, via `PersonLensService.RunLookupJson`,
  launches `LensWorker.ps1` as the **interactive user** using a one-shot **scheduled task**
  (`LogonType Interactive` = the logged-on token, *no password*; `RunLevel Limited` =
  medium integrity). `Shell.Application` was tried and rejected — it only de-elevates within
  the *same* user, so it left the child in the admin context. The task action wraps pwsh in
  `conhost.exe --headless`: a console app's window is created before `-WindowStyle Hidden`
  can hide it, so an interactive-token task would otherwise flash a console on the desktop.
- `LensWorker.ps1` (the de-elevated child) reads AD forest-wide via the **Global Catalog**
  (`GC://…`, then binds each object's home domain) and SCCM via the **AdminService REST**
  endpoint (`-UseDefaultCredentials`, no ConfigMgr module/PSDrive), and writes the bundle to
  a `%ProgramData%\DONUT\lens-<guid>` exchange folder shared with the elevated parent.
- The parse (`PersonLens.FromJson`) is pure/tested; the de-elevation itself is the overridable
  `RunLookupJson` seam. `HomePresenter` polls the pool job (like the AD search/unlock) and
  populates the `PersonLensViewModel`. The `%5C` (backslash) gotcha in the SCCM query is
  avoided by filtering on the forest-unique SAM (`endswith`) and exact-matching client-side.

**Securing the exchange (the bundle holds BitLocker recovery keys):**
- The exchange folder's inherited ACL is **stripped** (ProgramData grants all local users
  read) down to SYSTEM / Administrators / the interactive user.
- Every payload is **AES-256-CBC encrypted** with a per-lookup key (`key.bin`, 32-byte key +
  16-byte IV, written by the parent; `PersonLensService.ProtectText`/`UnprotectText` are the
  unit-tested twins of the child's inline encrypt). Nothing touches disk in the clear.
- The folder is deleted in the lookup's `finally`; stale `lens-*` leftovers (crashed runs)
  are swept before each lookup, and **all** are purged when the main window closes. The
  per-person UI cache is **memory-only** (`HomePresenter.LensCache`, 15-min TTL), so it dies
  with the process.

**Keeping it fast:**
- **One SCCM call total** — the affinity query (person → WSIDs). Everything per-device
  (OS, `lastLogonTimestamp` as a coarse "last seen", BitLocker) is read from the
  computer's AD object, which the worker GC-locates anyway. The AdminService `/wmi`
  route's OData translator rejects richer filters (`or`, backslashes) with **404**, so
  per-device SCCM detail queries were dropped rather than fought.
- The affinity query runs on a **thread job in parallel** with the AD user read: the
  finder row's SAM is passed down as a hint (`-Sam`), so the child doesn't wait for AD
  to resolve it before asking SCCM.
- The child writes **sequential partial bundles** which `RunLookupJson` streams to
  `PollLens` on the Information stream (tag `LensPartial`): partial 1 = directory facts
  (~1–2 s), partial 2 = name-only device rows the moment affinity answers; the per-device
  OS/last-logon/BitLocker reads fill in behind them in the final bundle.
- Writes are atomic (`.tmp` + rename), the parent polls at 100 ms with no settle sleep, and
  the TTL cache makes re-picking the same person instant.

### The `InstallWorker.ps1` Script
**Challenge:** This script is copied to `%LOCALAPPDATA%` and runs independently to handle updates/rollbacks.

**Refactor Strategy:**
- **Standalone Script:** `InstallWorker.ps1` should **not** be converted into a class. It must remain a standalone script file in `src/Scripts/` so it can be easily copied and executed by the `SelfUpdateService`.
- **Resource Loading:** The `SelfUpdateService` will need to know the path to this script to copy it.
- **Token Security:** The `SelfUpdateService` must continue to use **DPAPI (CurrentUser)** to encrypt/decrypt the GitHub Device Flow tokens, ensuring security is maintained during the refactor.
- **Simplified Updates:** Since `logs`, `reports`, and `wsid.json` now reside in `%LOCALAPPDATA%\DONUT`, they are unaffected by the MSI installation in `Program Files`. The complex backup/restore logic can be removed.
- **Hash-based worker copy:** Copy `InstallWorker.ps1` to `%LOCALAPPDATA%\DONUT` only when the SHA-256 differs, to avoid unnecessary writes.
- **Downloader hardening:** Keep SHA-256 verification of the MSI, HTML/SSO download guards, rollback when the latest tag is lower than installed, and silent reuse/refresh of stored Device Flow tokens.

### Packaging & Deployment (Visual Studio)
**Challenge:** The project was previously packaged using PowerShell Studio with specific settings (Windows Tray App engine, Admin rights, specific GUIDs). We are switching to Visual Studio Community edition for packaging, since it is free.

**Refactor Strategy:**
- **C# Wrapper (`Donut.Launcher`):**
    - **Type:** C# .NET 9.0 Windows Application (`<OutputType>WinExe</OutputType>`).
    - **Tray Functionality:** To match the "Windows Tray App" engine, the wrapper will implement `System.Windows.Forms.NotifyIcon`. This ensures the app runs in the background with a system tray icon, maintaining the original user experience.
    - **Manifest:** The application manifest will be configured to require `Administrator` privileges (`<requestedExecutionLevel level="requireAdministrator" />`), matching the `AsAdmin=1` setting.
- **MSI Installer (Visual Studio Installer Project):**
    - **UpgradeCode:** We **MUST** use `{FD0DF01A-1A35-454C-AF08-5BE6B458C6A7}`. This tells Windows Installer that this new MSI is an upgrade to the existing DONUT application, allowing it to replace the old version seamlessly.
    - **ProductCode:** A new GUID will be generated for each version (e.g., 2.0.0).
    - **Architecture:** The installer will be targeted for **x64** (`Platform=64 Bit Package`).
    - **Scope:** Per-Machine installation (`AllUsers=1`).

### UI & Threading
**Challenge:** WPF UI updates must happen on the UI thread.

**Refactor Strategy:**
- **High-Frequency Updates (Logs):** As decided in the "Parallel Execution" section, we will use a **Polling Pattern** for logs. The View (or Presenter) will use a `DispatcherTimer` to drain the thread-safe queue and update the UI in batches. This prevents UI freezing caused by flooding the Dispatcher with individual event invocations.
- **State Changes (Events):** To avoid any direct interference from background threads (which caused freezing issues in the past), we will **not** use `Dispatcher.Invoke` or `BeginInvoke`. Instead, state changes (e.g., `ScanStarted`, `ScanCompleted`) will update a thread-safe state object or queue. The same `DispatcherTimer` used for logs will poll this state and update the UI controls (buttons, status bars) on the next tick.
- **ApplyUpdates two-phase flow:** Mirror the existing behaviour: temporary scan config -> run scan -> copy report XML -> gather remote driver/app data via PsExec -> brand-based driver/app matching -> per-host confirmation popup (skip apply if not confirmed) -> skip apply when no updates are found -> copy updates list to clipboard.
- **Manual reboot detection:** Parse log lines for reboot-required vs auto-reboot; surface a completion popup listing machines needing manual reboot. Pre-seed the manual reboot list when config flags disable automatic reboot (`reboot`/`forceRestart`).
- **Multi-device safety prompt:** If ApplyUpdates is enabled and multiple hosts are queued, show a single confirmation listing all targets before enqueueing runspaces.

### Configuration & Persistence
**Challenge:** `config.txt` and `WSID.txt` persistence.

**Refactor Strategy:**
- **JSON Migration:** `config.txt` will be refactored into JSON format (`config.json`) to support common standards.
- **Location:** `wsid.txt` and `config.json` will be stored in `%LOCALAPPDATA%\DONUT\` to persist across updates.
- **ConfigManager:** This service will handle reading/writing both configuration files, prioritizing the `%LOCALAPPDATA%` version if it exists.
- **Modern Config Structure:** The config uses a simplified format aligned with Dell Command Update CLI:
  - `activeCommand`: Single field specifying which command is active (`scan` or `applyUpdates`)
  - `throttleLimit`: Global parallel execution limit
  - `commands`: Dictionary of command configurations with `args` hashtables
  - No more `enabled` flags on each command - only `activeCommand` matters
- **DCU CLI Argument Building:** The `AppConfig.BuildDcuArgs()` method generates proper DCU CLI format:
  - Uses `-option=value` syntax (not `/option`)
  - Boolean `true` → `-silent` or `-reboot=enable`
  - Boolean `false` → omitted (or `=disable` if explicit)
  - Empty strings → omitted
  - Strings with spaces → quoted
- **Default Merge:** `AppConfig` constructor merges user settings with `[AppConfig]::Defaults`, ensuring all expected keys exist

#### Example `config.json`
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

#### DCU CLI Options Reference
Based on [Dell Command Update CLI Reference](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-update-cli-commands):

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

### PowerShell Constraints to Retain
- **Absolute script paths in runspaces:** Child runspaces must receive absolute script paths because `AddScript` rejects relative paths in the packaged build.
- **Window chrome for resize:** Use XAML `WindowChrome` with `AllowsTransparency="False"`, `WindowStyle="None"`, `ResizeMode="CanResize"`, and `WindowChrome.ResizeBorderThickness="6"` (or similar) to keep edge/corner resize without any P/Invoke.

---

## 5. Testing Strategy

The core principle for testing this new structure is **Dependency Injection**.

### The Problem: Side Effects
Code that directly touches the network or file system is hard to unit test.
```powershell
# Hard to test!
$ip = [System.Net.Dns]::GetHostAddresses($computer)[0]
```

### The Solution: The Wrapper Pattern
We create a class whose *only* job is to touch the network. We can then "mock" (fake) this class during tests.

#### 1. The Wrapper Class (`src/Core/NetworkProbe.psm1`)
```powershell
class NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.Dns]::GetHostAddresses($hostname)[0]
    }
}
```

#### 2. The Service Class (`src/Services/RemoteServices.psm1`)
This service accepts a `NetworkProbe` in its constructor.
```powershell
class RemoteJobService {
    hidden $NetworkProbe
    RemoteJobService($probe) {
        $this.NetworkProbe = $probe
    }
    # ... uses $this.NetworkProbe.ResolveHost() ...
}
```

#### 3. The Pester Test (`tests/Unit/RemoteServices.Tests.ps1`)
We create a **Mock** version of the probe that returns fake data.
```powershell
class MockNetworkProbe : NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.IPAddress]::Parse("192.168.1.100")
    }
}

It "Successfully scans a valid device" {
    $fakeProbe = [MockNetworkProbe]::new()
    $service = [RemoteJobService]::new($fakeProbe)
    $result = $service.ScanDevice("Valid-PC")
    $result | Should -Be "Success: 192.168.1.100"
}
```

### Summary of What to Test
| Component | What to Test | How to Mock |
| :--- | :--- | :--- |
| **Models** | Properties, simple validation. | No mocking needed. |
| **Services** | Logic, error handling. | Mock `NetworkProbe`, `FileSystem`, `PsExecWrapper`. |
| **Presenters** | UI flow (e.g., "Did clicking Scan call the Service?"). | Mock the `Service` class. |
| **Core** | The actual .NET/exe calls. | **Don't unit test these.** Use Integration tests. |

### Test Structure
- **Unit (tests/Unit):**
  - Config parsing/build (one enabled command, throttle required, blank args ignored, flag handling).
  - Service logic with mocks (`NetworkProbe`, `PsExecWrapper`, file system): scan/apply two-phase orchestration, driver matching, confirmation triggers.
  - SelfUpdateService token/decision logic with mocked GitHub API.
- **Integration (tests/Integration):**
  - Remote execution paths (DNS failure, Reverse-DNS mismatch, RPC 1722) with a mock/loopback target and temp UNC folders to verify log/report copy.
  - ApplyUpdates flow using report XML + fake driver/app data to assert confirmation/skip and clipboard list generation.
  - Updater flow: SHA-256 verification, HTML/SSO rejection, rollback when remote < local, hash-based worker copy, backup/restore of logs/reports/config across install simulation.
  - Backup/restore persistence: Run backup then restore into a fresh temp tree and compare hashes for logs/reports/config.

## 6. Code Coverage

To ensure the reliability of the refactored code, we use Pester for unit and integration testing. You can generate a visual HTML code coverage report to see which lines of code are covered by tests.

### Generating the Report

Run the generation script from the project root:

```powershell
tests/Generate-CoverageReport.ps1
```

This script will:
1. Run all Pester tests in `tests/Unit`.
2. Generate a `coverage.xml` file in JaCoCo format.
3. Convert the XML into a full HTML report in the `CoverageReport` directory.

### Viewing the Report

Open the generated report in your browser:
`CoverageReport/index.html`

### Credits

The HTML report generation is powered by [JaCoCo-XML-to-HTML-PowerShell](https://github.com/constup/JaCoCo-XML-to-HTML-PowerShell) by [constup](https://github.com/constup). This tool allows us to generate beautiful coverage reports using only PowerShell, without requiring external .NET tools or licenses.
