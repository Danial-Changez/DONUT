---
title: Machine details & storage
description: The per-machine detail pane - inventory, available updates, live logs, and the biggest-folders storage scan.
---

Selecting a machine opens its detail pane. The data is prefetched in the background
when the row is added or selected, so it's usually already there when you look.

## Overview strip

A lightweight CIM probe gathers the essentials — model, Dell service tag, BIOS
version, battery health, free disk space, and uptime. The probe re-runs when stale;
**Refresh** forces it.

## Available updates

Once any scan completes — a plain **Scan** or the scan phase of an apply — the pane
lists each update DCU found, sorted most-urgent first: name, category, urgency badge
(Urgent / Recommended / Optional), the version transition (`1.2.0 → 1.4.1`), and
download size. Selecting a machine with a recent scan shows its results without re-running.

## Live log

While a run is active, the pane tails the remote DCU output log line by line — the
same content that lands in `%ProgramData%\DONUT\data\logs\<hostname>.log`.

Every line carries a dim `HH:mm:ss` stamp and is colour-coded by severity: errors
red with an `[Error]` tag, warnings yellow with `[Warn]`, completed-run lines
green, everything else the plain terminal tone. The **Copy** button in the
terminal's corner copies the whole visible log for a ticket or a teammate.

## Storage scan (biggest folders)

**Storage scan** runs WizTree headlessly on the target and shows the largest
folders on `C:` as an expandable tree with sizes. Useful before pushing large
updates to a nearly-full disk.

:::note
WizTree's `wiztree64.exe` is vendored under `src/Tools/` (see the note there about
licensing); the scan deploys it to the target, parses the CSV export, and cleans up.
:::

## Clearing folder contents

Each folder row in the tree has a checkbox. Tick the ones you want to reclaim, then
**Clear selected** in the card header. Checkboxes are hierarchical, like the Windows
"Turn Windows features on or off" list: checking a parent checks every clearable folder
under it, and unchecking one child leaves the parent half-filled (indeterminate) and
spares that child — so you can clear most of a folder while keeping specific subfolders.
DONUT shows a confirmation dialog listing the folders and their combined size before
anything is removed — the operation **clears each
folder's contents but keeps the folder itself** (so a cache like `ccmcache` is emptied, not
removed, and the owning service refills it). It runs as SYSTEM on the target and **cannot be
undone**. When it finishes, the storage scan re-runs so the tree reflects the freed space.

:::caution
Protected system locations are never clearable — they don't get a checkbox at all: the
volume root, `Windows` (and everything under it, including `Installer`), `Program Files`
/ `Program Files (x86)`, `ProgramData`, `System Volume Information`, `$Recycle.Bin`,
`Recovery`, and the `Users` container itself (individual profiles/subfolders under it are
clearable). The rule is enforced twice — in the UI and again inside the remote script —
so a folder that shouldn't be touched can't be, even by mistake.

The remote script additionally refuses to touch **any profile that is currently logged on**
(the console user *and* any RDP sessions — every profile with a loaded registry hive), so an
active user's data is never cleared even if their profile folder was selected. Stale (logged-off)
profiles can still be cleared.

A short allowlist of well-known reclaimable caches *is* clearable even though it lives under
`Windows`: `ccmcache` (SCCM), `Temp`, `SoftwareDistribution\Download` (Windows Update),
`Prefetch`, `Logs`, and `Downloaded Program Files`. The owning service recreates them as
needed. To add or remove entries, edit `FolderDeletionPolicy.AllowedCaches` **and** the
mirrored list in `ExecutionService.BuildDeleteCommand`.

Because both lists are string comparisons, every path is canonicalized before they are applied —
`..` and `.` segments are resolved, `/` is normalised, Windows' trailing dot/space stripping is
applied, and 8.3 aliases (`PROGRA~1`) are refused. Without that, `C:\temp\..\Windows\System32`
reads as an ordinary `temp` folder. On the target the clear also refuses a selected folder that is
a **junction**, and never descends through one while clearing, so a link planted under an allowed
root can't redirect the delete into the directory it points at.

If the target's profile enumeration fails, the clear stops rather than proceeding without the
logged-on-profile protection — a run that can't verify who is signed in does nothing.
:::

## Under the hood

![Inventory and storage sequence diagram](/diagrams/inventory_sequence_diagram.svg)

*Source: [`inventory_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/inventory_sequence_diagram.puml)*
