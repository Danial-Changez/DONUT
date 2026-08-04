---
title: The machine list
description: Adding machines, running one or all, and how the list is ordered.
---

The Home list is DONUT's center: one row per machine, newest action first.

## Adding machines

- Type hostnames in the search bar — separated by commas or new lines — and press
  Enter (or click **Add**). Each becomes a row and gets an inventory probe; adding
  never scans or applies on its own.
- Or pick a computer from the [AD finder dropdown](./ad-finder.md). Enter acts on
  real results only — the top-ranked computer when any matched, else the top
  user — so a prefix like `CAP-` adds an actual machine, never a junk card.

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

## Status stays live

A row's online/offline state is a **verdict with a shelf life**, not a snapshot:

- Any failed job whose cause is offline-class (host offline, unresolvable, connection
  lost, timed out) — including inventory and storage probes — flips the row's verdict
  immediately, then a background re-probe confirms it (or restores Online if the
  failure was transient).
- Verdicts older than the resolve TTL re-probe automatically in the background, so a
  machine that goes offline while sitting idle in the list flips on its own — no
  re-add or re-select needed.
- If a re-probe itself fails (e.g. the DC is unreachable), the row shows the neutral
  not-yet-known state rather than a stale green.

The status dot follows one precedence everywhere — attention → offline → online →
last-run colour — the same rule that orders the list.

## Empty list?

The blank slate lists the three first steps (add machines, or search a person, then
Run). If you have a bundled host list (`WSID.txt`), DONUT seeds recent machines from
it on first run.
