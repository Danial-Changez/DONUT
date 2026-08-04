---
title: UI and threading
description: The polling rules that keep WPF responsive, the terminal log line model, and the update-flow UI logic.
---

WPF UI updates must happen on the UI thread, and past freezes came from
background threads touching the UI directly. The presenter/view-model structure
itself is mapped in [Key classes](./key-classes.md); this page covers the
threading rules and the UI-side job flows.

![UI class diagram](/diagrams/class_ui.svg)

*Source: [`class_ui.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_ui.puml)*

## Threading rules

- **Polling, not marshalling:** state changes (`ScanStarted`, `ScanCompleted`,
  log lines) update a thread-safe state object/queue; `DispatcherTimer` ticks
  drain it on the UI thread in batches. DONUT does **not** use
  `Dispatcher.Invoke`/`BeginInvoke` for this - flooding the dispatcher with
  per-event invocations was a freeze source. (One deliberate exception:
  `TourPresenter` queues a single `BeginInvoke` at `Loaded` priority so a tour
  step positions after layout.)
- Three poll loops share that rule: the job pump in
  `AsyncJobPresenter.PumpJobs` (a ~200 ms tick; `HomePresenter` routes each job
  kind's polled output and completion), `FinderPresenter`'s own timers for its
  interactive pool jobs (deliberately never the pump - see the note at the top
  of that file), and `MainPresenter.RunOnPool`/`ReapPoolJobs` for one-shot
  shell work. Feature timers (tray, toasts, watchdog, deferred warms) follow
  the same pattern.

## The terminal log

- Every detail-pane terminal line is a typed `LogLine` (severity + normalized
  dim `HH:mm:ss` stamp + text). Severity is decided at the source:
  `AsyncJob.DrainStream` keeps the PowerShell stream a record arrived on, and
  dcu-cli wording only ever upgrades Info to Warn - the return code stays the
  authority on failure.
- The renderer is a chromeless virtualized ListBox (`lstDetailLog`), so a
  2000-line ring buffer realizes only the visible rows; the terminal's Copy
  button (`InventoryPresenter.CopyHostLog`) replaces cross-line drag-selection.
- Severity colors and the `[Error]`/`[Warn]` text tags are documented in the
  [UI reference](../ui-reference.md).

## Update-flow UI logic

- **ApplyUpdates two-phase flow:**
  1. Temporary scan config, then the scan phase runs remotely.
  2. Copy the report XML; gather remote driver/app data via PsExec.
  3. Brand-based matching (`DriverMatchingService`).
  4. Copy the updates list to the clipboard, then confirm before the apply
     phase; skip apply when no updates (a scan's DCU 500 short-circuits with
     "No updates found").
- **Manual reboot detection:** the worker reports `RebootRequired` in its
  result, and the host gets a per-host toast plus card status;
  `ManualRebootQueue` tracks the batch.
- **Multi-device safety prompt:** a Run all consents **once** for the whole
  batch - a single confirmation listing all targets before enqueueing
  (`BatchApplyHosts` then skips the per-host dialog).
