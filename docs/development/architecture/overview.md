---
title: Architecture overview
description: How DONUT is built - running from source, the directory structure, the MVVM layering, and the presenter seams.
---

DONUT is a WPF/PowerShell fleet management app for Dell workstations. Its
subsystems are remote driver updates (Dell Command Update over PsExec), a live
Active Directory finder, the User Lens (a de-elevated user-to-device lookup),
per-machine inventory and storage, and the tray, hotkey, and self-update plumbing.
Each subsystem has its own page:

- [Runspaces and workers](./runspaces-and-workers.md): the job pool, process
  isolation, and the warm/staging rules.
- [Remote execution](./remote-execution.md): the PsExec transport and dcu-cli
  return-code handling.
- [User Lens](./user-lens.md): the de-elevated agent and its exchange.
- [AD query rules](./ad-queries.md): LDAP filter shapes and bounds.
- [UI and threading](./ui-and-threading.md): presenters, view-models, and the
  polling rules.
- [Elevation and autostart](./elevation.md): the elevation model, first-run
  setup, and the one data root.
- [PowerShell constraints](./powershell-constraints.md): language and packaging
  constraints the code must keep honoring.

The visual counterparts are [Runtime flows](./runtime-flows.md) and
[Key classes](./key-classes.md). Conventions live in
[Coding style](../coding-style.md); the history behind the rules is in
[Design decisions & postmortems](../decisions.md).

## Run from source

Clone the repo and run:

```powershell
pwsh -File src\Start-Donut.ps1
```

The script compiles the C# helpers in-process, so it needs nothing beyond
PowerShell 7+. Started from Windows PowerShell 5.1 or an MTA host, it relaunches
itself under `pwsh -Sta`. `-Tray` starts hidden in the tray (the packaged launcher
takes `--tray`); `-DebugLog` forces verbose logging for the session. Maintainers
build the MSI with `pwsh -File tools\Build-Installer.ps1 -Version <x.y.z>`. Plain
`dotnet` is the only prerequisite; the WiX SDK restores itself.

:::note
Defender may slow or quarantine an unsigned dev build. If startup feels slow, add
an exclusion for your checkout's `bin\Debug\...` output folder.
:::

## Component view

![Component diagram](/diagrams/component_diagram.svg)

*Source: [`component_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/component_diagram.puml)*

## Directory structure

```text
root/
├── assets/                 <-- Images and screenshots
├── docs/                   <-- Documentation (also the source of this site)
├── src/                    <-- Source code
│   ├── Core/               <-- Base classes, enums, infrastructure (reusable)
│   ├── Lib/                <-- Bundled binary dependencies (e.g. QRCoder.dll)
│   ├── Models/             <-- Data classes (DTOs) + pure mappers
│   ├── Services/           <-- Business logic (DONUT-specific)
│   ├── Scripts/            <-- Standalone scripts + remote workers
│   ├── UI/                 <-- Views (XAML), Styles, ViewModels, Presenters
│   └── Launcher/           <-- C# launcher project (+ Donut.Mvvm base types)
├── tests/                  <-- Pester tests (Unit/ and Integration/)
├── web/                    <-- Astro Starlight scaffold for this docs site
├── README.md
└── LICENSE

Runtime data: %ProgramData%\DONUT\data\  (config/, logs/, reports/)
```

`Models` are pure data structures and mappers; `Services` hold DONUT-specific
business logic; `Core` is generic infrastructure. Runtime data lives outside
`Program Files`, so an MSI upgrade never touches it.

## Architecture (MVVM)

Every surface renders through data bindings: the machine list, detail pane,
folders tree, finder dropdown, toasts, dialogs, login, settings, and shell chrome
each bind their own view-models.

1. **Model layer (`src/Models`, `src/Services`, `src/Core`)**: data, business
   logic, infrastructure.
2. **View layer (`src/UI/Views`)**: XAML only, no code-behind. Pages compose from
   files: `HomeView.xaml` is a slot-frame shell whose regions live under
   `Views/Home/`, loaded by `HomePresenter.ComposeRegions` via `ViewLoader`. Every
   `XamlReader.Load` root owns its file's namescope, so a presenter is handed its
   region root and cannot reach into another region's names.
3. **ViewModel layer (`src/UI/ViewModels`)**: bindable state (`ObservableObject`
   subclasses) + `RelayCommand`s; calls the pure Model mappers so WPF-free logic
   stays unit-testable.
4. **Presenter layer (`src/UI/Presenters`)**: coordinators that load views, own
   background jobs and timers, build view-models, and wire commands.

### The launcher embeds `src\`, so installed builds need a rebuild

`Donut.Launcher.csproj` embeds every `.psm1`/`.ps1`/`.xaml` under `src\` as
resources, and the launcher self-extracts them beside the exe before hosting
PowerShell **in-process**. So `[Environment]::ProcessPath` is `Donut.Launcher.exe`,
and `SourceRoot` is the extracted tree, *not* your clone.

:::caution
Editing a `.psm1` and pulling does nothing to an installed build. The running code
changes only when `Donut.Launcher.exe` is rebuilt and reinstalled. To test a
PowerShell-side change, run the dev path (`pwsh -File src\Start-Donut.ps1`).
:::

### The MVVM bases

PowerShell classes cannot declare CLR events, so two tiny C# bases
(`src/Launcher/`, namespace `Donut.Mvvm`) close the `INotifyPropertyChanged` gap:
**`ObservableObject`** (inherited by view-models; `Set`/`Raise`) and
**`RelayCommand`** (a minimal `ICommand` wrapping a PowerShell scriptblock).
Production compiles them into `Donut.Launcher`; `Start-Donut.ps1` `Add-Type`s them
on the dev path.

### Presenters are coordinators

The `*Presenter` classes act as coordinators/UI-services. Bindings are the default
render path, and presenters keep only the imperative work MVVM sanctions (dialog
lifecycles, live log appends, popup positioning, spotlight geometry, the WinForms
`NotifyIcon`). The name is retained by choice; the rationale and the per-presenter
list are in [Design decisions](../decisions.md#presenters-keep-their-name).

`HomePresenter` is the largest coordinator (the `AsyncJob` pump, run/apply flow,
machine list). Three clusters are carved off it (`FinderPresenter`,
`InventoryPresenter`, `ResolutionCoordinator`) along one seam: duck-typed
`[object] $Home` back-ref, the gate stays with its owner, shared objects passed by
reference. See [Design decisions](../decisions.md#the-coordinator-seam).

### Tray, hotkey, single instance

- One tray icon, owned by the WPF UI thread (`TrayPresenter`), so surfacing the
  window needs no cross-thread marshalling; dev and prod behave identically.
- The global hotkey uses `RegisterHotKey` + a WndProc hook, never
  `SetWindowsHookEx`/Raw Input/key-state polling, which observe the global
  keystroke stream and trip AV/EDR keylogger heuristics.
- Single instance via a `Local\DONUT.SingleInstance` mutex + a
  `Local\DONUT.ShowRequest` event: a second launch signals the running instance to
  surface and exits silently. Autostart and the elevation handshake are on
  [Elevation and autostart](./elevation.md).

### Self-update seams

- `SelfUpdateService` owns release discovery, download, hash verification, and the
  MSI apply; `UpdatePresenter` drives it. The default Owner/Repo is queried
  anonymously; only when the repo refuses does `LoginPresenter` run the GitHub
  Device Flow, once; tokens are DPAPI-protected. A fork points Owner/Repo at
  itself and sets `ClientId` to its own GitHub App.
- `InstallWorker.ps1` stays a standalone script so `SelfUpdateService` can copy it
  to the data root and run it independently for updates/rollbacks (the MSI is
  SHA-256-verified first). The version compare reads the installed
  `DisplayVersion` from the uninstall key.
- The check follows the configured channel: stable reads `releases/latest`, beta
  (`betaUpdates`) the release list, so prereleases count too. Which package it then
  applies follows the install: a copy running inside the `InstallLocation` its
  uninstall key records takes the MSI, anything else takes the zip and replaces its
  own files (`IsPortable`). The MSI path passes that `InstallLocation` back as
  `INSTALLFOLDER`, so an MSI install outside Program Files stays where it is.
- **Publishing a release** is the workflow's job, not a checklist: a push to `main`
  publishes a prerelease and a promotion flips its flag, both covered in
  [Releasing](../releasing.md). The presenter picks the first `*.msi` asset and
  keys everything off the tag, so a tag *older* than the installed version is
  offered as a rollback - how a bad release gets pulled.

### First-run guided tour

`TourPresenter` walks `TourSteps` (pure data, unit-tested headless) one step at a
time: dim panels frame a spotlight over the target control with a callout beside
it. It auto-runs once (`hasSeenTour`) and replays from the `?` button. Targets live
inside region namescopes, so they resolve through `HomePresenter.FindHomeElement`,
not `Window.FindName`.
