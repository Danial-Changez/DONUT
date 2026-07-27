---
title: Architecture overview
description: How DONUT is built - the directory structure, the MVVM layering, and the design decisions behind the presenter seams.
---

How DONUT is built: a WPF/PowerShell tool that runs the Dell Command Update (DCU)
CLI remotely across many Dell machines in parallel, with a per-machine detail panel,
a live Active Directory finder, and a de-elevated user Lens. This is the standing
architecture reference; the visual counterpart is the diagram set on
[Runtime flows](./runtime-flows.md) and [Key classes](./key-classes.md).
Comment/layout conventions live in [Coding style](../coding-style.md).

:::note
The project began as a script-based tool and was refactored to an OOP structure,
first to a Passive-View MVP and then to MVVM. That migration is complete; this
document describes the result, not the plan.
:::

## Directory structure

The structure emphasizes testability and a layered UI architecture.

```text
root/
├── assets/                 <-- Assets
│   ├── Images/
│   └── Screenshots/
├── docs/                   <-- Documentation (also the source of this site)
├── src/                    <-- Source Code
│   ├── Core/               <-- Base classes, enums, infrastructure (reusable)
│   ├── Lib/                <-- Bundled binary dependencies (e.g. QRCoder.dll)
│   ├── Models/             <-- Data classes (DTOs) + pure mappers
│   ├── Services/           <-- Business logic (DONUT-specific)
│   ├── Scripts/            <-- Standalone scripts + remote workers
│   ├── UI/                 <-- UI Layer
│   │   ├── Views/          <-- XAML files (shells + composed regions; Home/, Settings/)
│   │   ├── Styles/         <-- XAML styles
│   │   ├── ViewModels/     <-- Bindable state + commands
│   │   ├── Presenters/     <-- Coordinators / UI services (jobs, timers, dialogs)
│   └── Launcher/           <-- C# Launcher project (+ Donut.Mvvm base types)
├── tests/                  <-- Pester tests
│   ├── Unit/
│   └── Integration/
├── web/                    <-- Astro Starlight scaffold for this docs site
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

## Architecture (MVVM)

Every surface renders through data bindings: the machine list is a virtualizing
`ListBox` of `HostViewModel`s, the detail pane and overview strip bind to
`SelectedMachine.*`, and the folders tree, AD finder dropdown, toasts, dialogs,
login window, settings overlay, and shell chrome all bind their own view-models.

### The layers

1. **Model layer (`src/Models`, `src/Services`, `src/Core`)** — data, business
   logic, and infrastructure.
   - **Models**: data models and pure mappers (e.g. `AppConfig`, `FleetCardStatus`).
   - **Services**: project-specific modules (e.g. `SelfUpdateService`).
   - **Core**: general, reusable modules (e.g. `NetworkProbe`).
2. **View layer (`src/UI/Views`)** — XAML: structure, layout, `DataTemplate`s, and
   bindings. No code-behind. Pages compose from files: `HomeView.xaml` is a slot-frame
   shell whose regions live under `Views/Home/` (ActionBar / StatCards / MachinePane /
   DetailPane, with LensPane nested inside the detail region), loaded at startup by
   `HomePresenter.ComposeRegions` via `ViewLoader`; the settings page composes
   `SettingsView.xaml` + `Views/Settings/*` the same way. Every `XamlReader.Load` root
   owns its file's namescope, so a presenter is handed its region root and cannot reach
   into another region's names; `StaticResource` keys (converters) are declared
   per-file, shared styles live in `UI/Styles` and resolve via `DynamicResource`.
3. **ViewModel layer (`src/UI/ViewModels`)** — bindable state (`ObservableObject`
   subclasses) + `RelayCommand`s. Calls the pure Model mappers for display decisions,
   so WPF-free logic stays unit-testable.
4. **Presenter layer (`src/UI/Presenters`)** — coordinators/services: load views, own
   background jobs and timers, build the view-models, wire commands, and run the
   imperative shell work.

### The launcher embeds `src\` — installed builds need a rebuild

`Donut.Launcher.csproj` embeds every `.psm1`/`.ps1`/`.xaml` under `src\` (plus images,
fonts, and the `src\Tools` binaries) as resources, and `Program.ExtractEmbeddedApp`
self-extracts them to `%ProgramData%\DONUT\app` (SHA-256 verified per file) before
hosting PowerShell **in-process**. So `[Environment]::ProcessPath` is
`Donut.Launcher.exe`, and `SourceRoot` is the extracted tree — *not* your clone.

:::caution
**Editing a `.psm1` and pulling does nothing to an installed build.** The running code
comes from the exe's embedded copy; it changes only when `Donut.Launcher.exe` is
rebuilt and reinstalled. To test a PowerShell-side change without rebuilding, run the
dev path (`pwsh -File src\Start-Donut.ps1`), which loads the clone directly.
`tools\Diagnose-StartupTask.ps1` reports which build is actually extracted.
:::

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
**coordinator / UI-service**, not MVP passive-view presenter — bindings are the default
render path, and presenters keep only the imperative control work MVVM sanctions.
A rename to `*Coordinator`/`*Service` would be cosmetic churn across the UI
layer, so the name is retained by choice (`ToastService` already carries the accurate
suffix). The surfaces that stay deliberately imperative, each the standard MVVM answer:

- **`DialogPresenter`** is a *dialog service* — showing a modal and returning a result
  is inherently imperative; the dialog's *content* binds a `DialogViewModel`.
- **`MainPresenter`** keeps lazy Settings construction (the settings view builds on first
  settings-overlay open — a startup-cost win) and the Home fade-in; the shell's
  settings-overlay/chrome *inputs* are bound commands on `MainViewModel`.
- **`SettingsPresenter`** keeps its data-driven form binder: every named control in a
  command's option view maps 1:1 to a dcu-cli arg key, so a typed property per field
  would restate the key list for no behaviour gain. Settings persist in real time —
  there is no Save button; toggles and keybind changes write through immediately and
  fire their side-effects (hotkey re-registration, scheduled-task reconcile).
- **`TourPresenter`** computes spotlight/callout geometry against live control bounds —
  measurement is inherently view-side work.
- **`LoginPresenter`** owns the modal window lifecycle (content binds `LoginViewModel`).
- **`InventoryPresenter`** appends to the per-host terminal and resolves detail-pane
  seams by name — a live log append has no binding-friendly shape.
- **`FinderPresenter`** repositions/highlights the search dropdown popup imperatively;
  rows themselves bind `SearchRowViewModel`s.
- **`TrayPresenter`** drives the WinForms `NotifyIcon`, which has no binding surface.

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

### Tray, autostart, and global hotkey

- **One tray icon, owned by the WPF UI thread.** `TrayPresenter` creates the
  `NotifyIcon` on the STA UI thread whose dispatcher pumps its messages, so surfacing
  the window needs no cross-thread marshalling. It replaces the launcher's old icon, so
  the dev path (`Start-Donut.ps1`) and prod launcher behave identically. A hidden
  (`-Tray` / `--tray`) start runs the message loop with no window
  (`MainPresenter.ShowHidden`, `EnsureHandle` so the HWND exists for the hotkey) and
  defers the sign-in/update check until the window is first surfaced.
- **RegisterHotKey, never a keyboard hook.** The global hotkey uses
  `Donut.Interop.HotkeyManager` (user32 `RegisterHotKey` + a WndProc `HwndSource` hook)
  so it never observes the global keystroke stream. `SetWindowsHookEx`, key-state
  polling, and Raw Input are deliberately avoided — they trip AV/EDR keylogger
  heuristics. `WM_HOTKEY` arrives on the UI thread, so the PS `Pressed` handler is
  runspace-safe like any WPF event handler.
- **Autostart is a scheduled task, not a Run key.** `StartupTaskService` registers a
  `DONUT-<user>` task (logon trigger) so DONUT starts elevated with no per-logon UAC
  prompt (an HKCU Run key or `highestAvailable` manifest cannot). **Two accounts are
  involved, and conflating them is the bug this feature keeps re-learning:**
  - **Who TRIGGERS it** is always the *console* user — the only account that actually
    signs in — resolved via `Win32_ComputerSystem.UserName` (explorer's owner is the
    fallback; the "first explorer" can be another session's admin desktop). A trigger
    bound to an account that never logs on leaves the task `Ready` **forever**: no
    run, no error, nothing in any log.
  - **What it RUNS AS** comes from the process token, never `$env:` (under SYSTEM that
    names a nonexistent `DOMAIN\SYSTEM`, which Task Scheduler rejects with "No mapping
    between account names and security IDs"). Only when DONUT already runs *as the
    console user* is a per-user task viable (RunLevel Highest, Interactive).
    Otherwise — a SYSTEM token, or a separate admin account that never signs in — the
    task runs **as SYSTEM**, triggered at the console user's logon (PT15S delay so the
    desktop is up), and relaunches DONUT into that session via
    `psexec -accepteula -nobanner -s -i -d`, reproducing the manual SYSTEM launch. A
    per-user task cannot substitute: an Interactive principal needs a session that
    account doesn't have, and RunLevel Highest on a non-admin degrades to a standard
    token that CreateProcess refuses against the `requireAdministrator` launcher
    (`ERROR_ELEVATION_REQUIRED`, 0x800702E4 — no process, no UAC prompt). psexec
    resolves from `src/Tools` first, then PATH, absolute path baked into the action
    (SYSTEM's logon PATH may lack it). `-i` targets the **console** session; an RDP
    logon won't surface the tray (known limit).

  The task *name* derives from the console user, so an owner change would strand the
  old task — `RemoveStaleTasks` sweeps `DONUT-*` tasks that launch this install, never
  `DONUT-LensAgent` (`PersonLensService` owns that one). Failures toast the real
  reason (`Apply` records it in `LastFailure`, the worker returns it as `Reason`). The
  CIM calls run off the UI thread on the pool (`Apply-StartupTask.ps1`, reaped by a
  `DispatcherTimer`); `tools\Diagnose-StartupTask.ps1` reports the registered
  principal, trigger, and last result when it misbehaves.
- **Single instance via named handles.** A `Local\DONUT.SingleInstance` mutex plus a
  `Local\DONUT.ShowRequest` auto-reset event: the launcher owns them in prod,
  `Start-Donut.ps1` in dev, and a second launch signals the event (polled on a
  `DispatcherTimer`) so the running instance surfaces and the newcomer exits silently.

### First-run guided tour

`TourPresenter` walks `TourSteps` (pure data, unit-tested headless) one step at a
time: four dim panels frame a spotlight "hole" over the target control, with a callout
card beside it. It auto-runs once (`hasSeenTour` in config) and can be replayed from
the `?` button. Targets live inside the Home regions' own namescopes, so they resolve
through `HomePresenter.FindHomeElement` — which probes the shell and each region root —
rather than `Window.FindName` or a single view namescope.
