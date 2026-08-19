---
title: Applying updates
description: The two-phase apply flow - scan reuse, per-host confirmation, reboot handling, and connection-loss recovery.
---

Apply Updates installs what a scan found. It is deliberately a two-phase flow so you
always see what will be installed before anything changes.

## Run an apply

1. Click the mode pill until it shows **Apply Updates**.
2. Click **Run** on a machine (or **Run All** — a single confirmation lists every
   target first).
3. Confirm. The dialog names the count and warns that **BIOS and firmware
   installs cannot be rolled back** — the one part of an apply you cannot undo.
4. DONUT reuses a [fresh scan](./scanning.md#scan-results-are-reused-for-24-hours)
   (less than 24 hours old) or runs one, then shows a **per-host confirmation** with
   the update list. Confirm to apply; decline to skip that host.
5. When no updates are found, the apply is skipped automatically.

The updates list is also copied to the clipboard for pasting into tickets.

## Reboots

- DONUT parses the DCU log for reboot-required vs auto-reboot outcomes. A machine
  that needs a **manual reboot** says so in its own toast and a Windows
  notification when its run finishes.
- If your config disables automatic reboot (`reboot` off), machines are pre-seeded
  into the manual-reboot list.

## Network drops

If you disconnect while updates are running, the remote updates continue — you only
lose the live feed. DONUT keeps trying to reconnect and resume the log tail for
[`recoveryWindowMinutes`](../configuration/config-reference.md) (default 30) before
settling the row as *Unconfirmed*.
