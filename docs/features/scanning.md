---
title: Scanning for updates
description: Queue machines and run DCU scans on all of them in parallel, with live progress per row.
---

Scanning asks each machine's Dell Command Update what it would install, without
changing anything on the target.

## Run a scan

1. Add machines via the [search bar](./machine-list.md) (type names, or pick from the
   [AD finder](./ad-finder.md)).
2. Make sure the mode pill shows **Scan** — click it to cycle the mode if not.
3. Click a machine's **Run** button to scan just that host, or **Run all** to scan
   every idle machine in the list.

Each row streams live progress: the DCU milestone step (`N/5`), a percent bar, and
the log tail in the detail pane. Scans run in parallel across machines (bounded by
the [`throttleLimit`](../configuration/config-reference.md) setting).

## What a scan produces

- The row's status chip settles (completed / attention) and the update count is
  recorded.
- The detail pane lists each available update with its urgency, category, version
  transition, and size.
- The report XML and output log are copied back under `%LOCALAPPDATA%\DONUT`.

## Scan results are reused for 24 hours

A scan run within the last 24 hours is considered fresh: switching to Apply Updates
within that window reuses the report instead of re-scanning. The cache is
invalidated after an apply. See [Applying updates](./applying-updates.md).

## Under the hood

![Scan sequence diagram](/diagrams/scan_sequence_diagram.svg)

*Source: [`scan_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/scan_sequence_diagram.puml)*
