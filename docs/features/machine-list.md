---
title: The machine list
description: Adding machines, running one or all, and how the list is ordered.
---

The Home list is DONUT's center: one row per machine, newest action first.

## Adding machines

- Type hostnames in the search bar — separated by commas or new lines — and press
  Enter (or click **Add**). Each becomes a row and gets an inventory probe; adding
  never scans or applies on its own.
- Or pick a computer from the [AD finder dropdown](./ad-finder.md). When your text
  matches a machine-name pattern (e.g. `CAP-…`, `B1234…`, `WVD…` — editable via
  [`machineNamePatterns`](../configuration/config-reference.md)) the dropdown
  pre-selects **"Add ‹name› as a machine"** so Enter does the obvious thing.

## Running

- The **mode pill** shows the active command (**Scan** or **Apply Updates**); click
  it to cycle.
- **Run** on a row runs the active command on that host. **Run all** runs it on every
  idle machine (Apply asks once to confirm).
- Rows move to the top when you act on them, so current work stays visible.

## Order & clearing

The list keeps itself grouped worst-first: machines needing attention (failed runs or a
required reboot) rise to the top, then running, online, offline, and not-yet-known — each
alphabetical within its group. Acting on a machine also floats its row to the top so current
work stays visible. **Clear** removes settled (completed) rows in one click.

## Empty list?

The blank slate lists the three first steps (add machines, or search a person, then
Run). If you have a bundled host list (`WSID.txt`), DONUT seeds recent machines from
it on first run.
