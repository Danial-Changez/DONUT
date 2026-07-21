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

After a scan (or the scan phase of an apply), the pane lists each update DCU found:
name, category, urgency badge (Urgent / Recommended / Optional), the version
transition (`1.2.0 → 1.4.1`), and download size.

## Live log

While a run is active, the pane tails the remote DCU output log line by line — the
same content that lands in `%LOCALAPPDATA%\DONUT\logs\<hostname>.log`.

## Storage scan (biggest folders)

**Find big folders** runs WizTree headlessly on the target and shows the largest
folders on `C:` as an expandable tree with sizes. Useful before pushing large
updates to a nearly-full disk.

:::note
WizTree's `wiztree64.exe` is vendored under `src/Tools/` (see the note there about
licensing); the scan deploys it to the target, parses the CSV export, and cleans up.
:::

## Under the hood

![Inventory and storage sequence diagram](/diagrams/inventory_sequence_diagram.svg)

*Source: [`inventory_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/inventory_sequence_diagram.puml)*
