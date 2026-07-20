---
title: What is DONUT?
description: A WPF/PowerShell app that runs Dell Command Update remotely across many machines in parallel.
---

DONUT automates remote execution of the **Dell Command Update (DCU)** CLI across
multiple Dell computers on a network. You queue machines into a list, pick a mode
(**Scan** or **Apply Updates**), and DONUT runs the DCU CLI on each of them in
parallel — streaming progress, logs, and results back into the UI live.

## What it does

- **Remote DCU execution** — runs `dcu-cli.exe` on networked Dell machines over
  PsExec; no agents to install on targets.
- **Parallel execution** — PowerShell runspaces run many machines at once, with each
  machine shown as a row in the Home list. Rows are kept newest-action-first and can
  be filtered by status (All / Online / Offline / Attention).
- **Per-machine detail panel** — selecting a machine prefetches a lightweight
  inventory probe (model, Dell service tag, battery health, disk, uptime), lists the
  available updates found by a scan, and offers an on-demand **storage scan** of the
  biggest folders on `C:`.
- **24-hour scan reuse** — a scan run within the last 24 hours is reused instead of
  re-scanning; it is only re-run after an apply.
- **Live AD finder** — the search bar searches Active Directory (computers + users)
  across the org's forests as you type, and can unlock locked-out accounts inline.
- **User Lens** — picking a person opens their directory info and SCCM-assigned
  devices, with BitLocker recovery keys revealed on click.
- **Quality of life** — a system tray icon, a global show/hide hotkey, optional
  start-with-Windows, a first-run guided tour, and self-updates from your org's
  GitHub releases.

## How it's built

DONUT is a WPF app written in PowerShell 7 classes with a thin C# launcher, layered
as MVVM (Views → ViewModels → Presenters → Services/Models/Core). If you're here to
work on it rather than use it, start at the
[architecture overview](../development/architecture/overview.md).

## Next steps

1. [Install DONUT](./installation.md)
2. [First launch](./first-launch.md)
3. [Scan your first machines](../features/scanning.md)
