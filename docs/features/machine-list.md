---
title: The machine list
description: Adding machines, running one or all, and how the list is ordered.
---

The Home list is DONUT's center: one row per machine, newest action first.

## Adding machines

- Type hostnames in the search bar — separated by commas or new lines — and press
  Enter (or click **Add**). Each becomes a row and gets an inventory probe; adding
  never scans or applies on its own.
- Or pick a computer from the [AD finder dropdown](./ad-finder.md).

## Running

- The **mode pill** shows the active command (**Scan** or **Apply Updates**); click
  it to cycle.
- **Run** on a row runs the active command on that host. **Run All** runs it on
  every idle machine (Apply asks once to confirm).
- Rows move to the top when you act on them, so current work stays visible.

## Order and clearing

The list groups itself worst-first: machines needing attention (failed runs or a
required reboot), then running, online, offline, and not-yet-known — alphabetical
within each group. **Clear** removes every machine that is not running; each row's ✕
removes just that machine.

## Status stays live

A row's online/offline state is a verdict with a shelf life, not a snapshot:

| When | What happens |
|---|---|
| A job fails because the host is unreachable | The row flips immediately, then a background re-probe confirms it (or restores Online if it was transient) |
| A row sits idle past its verdict's lifetime | It re-probes on its own — no re-add or re-select needed |
| A re-probe itself fails | The row shows the neutral not-yet-known state rather than a stale green |

## Empty list?

The blank slate lists the three first steps (add machines, or search a person, then
Run). If you have a bundled host list (`WSID.txt`), DONUT seeds recent machines from
it on first run.
