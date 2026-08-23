---
title: What is DONUT?
description: A fleet management app for Dell workstations - AD search, remote driver updates, hardware inventory, and user-to-device lookup.
---

DONUT is a fleet management app for Dell workstations. It searches Active
Directory for machines and people, runs remote driver scans and updates through
**Dell Command Update (DCU)**, inspects hardware and storage, and looks up a
user's devices and BitLocker recovery keys.

For updates, you queue machines into a list, pick a mode (**Scan** or **Apply
Updates**), and DONUT runs them in parallel, streaming progress, logs, and results
back into the UI live.

## What it does

- **Fleet updates.** Scans and applies driver and BIOS updates by running
  `dcu-cli.exe` on the targets. No agents to install.
- **Many machines at once.** Each machine is a row in the Home list, kept
  newest-action-first and grouped so the ones needing attention are at the top.
- **Per-machine detail.** Model, service tag, battery health, disk, and uptime,
  plus the updates a scan found and an on-demand storage scan of the biggest
  folders on `C:`.
- **24-hour scan reuse.** A scan from the last 24 hours is reused instead of
  re-run; only an apply forces a fresh one.
- **Live AD finder.** The search bar searches computers and users across your
  forests as you type, and unlocks locked-out accounts inline.
- **User Lens.** Pick a person to see their directory info, their SCCM-assigned
  devices, and BitLocker recovery keys.
- **Quality of life.** A tray icon, a global show/hide hotkey, optional
  start-with-Windows, a first-run guided tour, and self-updates.

## Next steps

1. [Install DONUT](./installation.md)
2. [First launch](./first-launch.md)
3. [Scan your first machines](../features/scanning.md)

Working on DONUT rather than using it? Start at the
[architecture overview](../development/architecture/overview.md).
