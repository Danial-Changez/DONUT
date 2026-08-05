---
title: Machine details & storage
description: The per-machine detail pane - inventory, available updates, live logs, and the biggest-folders storage scan.
---

Selecting a machine opens its detail pane. The data is prefetched in the
background, so it's usually already there when you look.

## Overview strip

Model, Dell service tag, BIOS version, battery health, free disk space, and uptime.
It refreshes when stale; **Refresh** forces it.

## Available updates

Once any scan completes — a plain **Scan** or the scan phase of an apply — the pane
lists each update DCU found, most urgent first: name, category, urgency badge
(Urgent / Recommended / Optional), the version transition (`1.2.0 → 1.4.1`), and
download size. Selecting a machine with a recent scan shows its results without
re-running.

## Live log

While a run is active, the pane tails the remote DCU output line by line. Each line
carries a dim `HH:mm:ss` stamp and is colour-coded by severity — errors red,
warnings yellow, completed runs green. **Copy** grabs the whole visible log for a
ticket or a teammate.

## Storage scan (biggest folders)

**Storage** lists the largest folders on the target's `C:` drive as an
expandable tree with sizes. Useful before pushing large updates to a nearly-full
disk.

## Clearing folder contents

1. Tick the checkbox on each folder you want to reclaim. Checking a parent checks
   every clearable folder under it; unchecking a child spares that child and keeps
   its siblings ticked.
2. Click **Clear Selected** in the card header.
3. Review the confirmation dialog — it lists the folders and their combined size.
4. Confirm. When it finishes, the storage scan re-runs so the tree reflects the
   freed space.

Clearing empties each folder but keeps the folder itself, so a cache like
`ccmcache` refills normally.

:::caution
Clearing cannot be undone. Protected system locations (Windows, Program Files,
ProgramData, the volume root) never get a checkbox, and DONUT refuses to touch the
profile of anyone currently signed in — including active RDP sessions.
:::
