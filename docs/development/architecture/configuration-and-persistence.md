---
title: Configuration and persistence
description: config.json, the recents store, logging locations, and the self-update seams.
---

Where DONUT keeps its state and how settings flow through the app.

![Configuration class diagram](/diagrams/class_config.svg)

*Source: [`class_config.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_config.puml)*

## Configuration

- **One machine-wide data root:** `DonutPaths` resolves `%ProgramData%\DONUT\data`, and
  `config.json`, `recents.json`, `WSID.txt`, the GitHub token, logs and reports all hang
  off it, so they persist across updates and reinstalls. It is deliberately not
  `%LOCALAPPDATA%`: that is
  per-account, and a de-elevated UI with privileged work under a different account would
  otherwise keep two of everything. `ConfigManager` reads/writes through that root and
  secures it on the run that creates it (SYSTEM, Administrators, the interactive user).
- **Note:** `config.json` is therefore writable by the standard user while supplying DCU
  arguments to elevated remote runs - an accepted widening, and the price of one store.
  See [Elevation and autostart](./elevation.md).
- **Structure:** `AppConfig` merges user settings with `[AppConfig]::Defaults` so
  all expected keys exist. The full key list is documented in the
  [config.json reference](../../configuration/config-reference.md).
- **`AppConfig.BuildDcuArgs()`** generates DCU CLI format: `-option=value`
  syntax, boolean `true` becomes `-silent`/`-reboot=enable`, `false` is omitted
  (or `=disable` where explicit), empty strings omitted, values with spaces
  quoted. See the [DCU command reference](../../configuration/dcu-commands.md).
- **Real-time settings:** the settings overlay has no Save button - every control
  persists on change (text fields on focus loss), and side-effectful keys
  re-apply immediately (hotkey re-registration, startup-task reconcile).

## Persistence and logging

- The recents store (`RecentConnectionsStore` over `RecentConnection`) persists
  per-host outcomes (last status, job type, update count, owner, operator-touch
  recency) into `config\recents.json` - its own file, capped at 50 on write and
  de-duplicated, so config.json stays settings-only and job traffic never
  rewrites it. A one-time migration lifts legacy `recentHosts` entries out of
  config.json on the first launch. Per-machine probe data is deliberately not
  in it: the inventory JSON and the disk-scan CSV in `reports\` are its stores,
  parsed on demand and memoized for the session (`InventoryPresenter`).
- Logs land in `%ProgramData%\DONUT\data\logs\` - `Donut.log` for the app plus one
  `<hostname>.log` copied back per remote run. The logging rules themselves
  (lock-free appends, debug gate, provenance stamp) are on
  [Runspaces and workers](./runspaces-and-workers.md#logging-and-diagnostics).

## Self-update seams

- `SelfUpdateService` owns the release discovery, download, hash verification,
  and MSI apply; `UpdatePresenter` drives it. The default Owner/Repo is the
  public upstream and is queried anonymously - no sign-in exists on that path.
  Only when the repo refuses (a private fork: 404 anonymous, or 401 on a dead
  token) does `LoginPresenter` run the GitHub Device Flow, once; tokens are
  DPAPI-protected (CurrentUser). A fork points Owner/Repo at itself and sets
  `ClientId` to its own GitHub App.
- `InstallWorker.ps1` stays a standalone script (not a class) in `src/Scripts/`
  so `SelfUpdateService` can copy it to the data root and run it independently
  for updates/rollbacks (the MSI it installs is SHA-256-verified first).
- `StartupTaskService` reconciles the start-with-Windows scheduled task from the
  same config seam (`Apply-StartupTask.ps1` applies it out of process).
