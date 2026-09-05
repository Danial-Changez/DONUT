---
title: Scanning for updates
description: Queue machines and run DCU scans on all of them in parallel, with live progress per row.
---

Scanning asks each machine's Dell Command Update what it would install, without
changing anything on the target.

## Run a scan

1. Add machines via the [search bar](./machine-list.md) (type names, or pick from the
   [AD finder](./ad-finder.md)).
2. Make sure the mode pill shows **Scan**; click it to cycle the mode if not.
3. Click a machine's **Run** button to scan just that host, or **Run All** to scan
   every idle machine in the list.

Each row streams live progress: the DCU milestone step (`N/5`), a percent bar, and
the log tail in the detail pane. Scans run in parallel across machines (bounded by
the [`throttleLimit`](../configuration/config-reference.md) setting).

Remote work needs administrator rights: without them, **Run**, **Run All**, and
the detail pane's **Refresh** ask once and restart DONUT elevated, then carry on
with the click that asked - the same gate **Storage** uses.

DONUT drives Dell Command Update, so only Dell hardware can be scanned or
updated. A non-Dell target (a Lenovo, say) fails its run up front with a message
that names the manufacturer, instead of a generic failure minutes in.

## What a scan produces

- The row's status chip settles (completed / attention) and the update count is
  recorded.
- The detail pane lists each available update with its urgency, category, version
  transition, and size.
- The report XML and output log are copied back under `%ProgramData%\DONUT\data`.

## Scan results are reused for 24 hours

A scan run within the last 24 hours is considered fresh: switching to Apply Updates
within that window reuses the report instead of re-scanning. The cache is
invalidated after an apply. See [Applying updates](./applying-updates.md).
