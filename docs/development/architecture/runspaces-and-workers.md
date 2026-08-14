---
title: Runspaces and workers
description: The job pool, worker process isolation, the warm rules, and the diagnostics that keep them honest.
---

How DONUT runs background work: a runspace pool for throttling, child `pwsh`
processes for isolation, and a set of warm/staging rules. Most rules here are
guarded regression fixes — the history is in
[Design decisions & postmortems](../decisions.md), and the named tests enforce the
rules statically.

![Runspaces and workers class diagram](/diagrams/class_runspaces.svg)

*Source: [`class_runspaces.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_runspaces.puml)*

## Worker process isolation

Each job runs in its own child `pwsh` process; the pool exists for throttling
(`throttleLimit`) only. Concurrent `using module` class-graph compiles deadlock on
PowerShell's module-load lock, so no worker graph ever loads on a pool runspace.

- Each runspace runs a tiny class-free launcher that spawns `RemoteWorker.ps1` and
  returns its result. `WorkerProcess` owns the isolation mechanics (args to temp
  file, launcher scriptblock, result file to verdict); `AsyncJob` orchestrates the
  lifecycle.
- The child executable is `WorkerProcess.FindPwsh()`, never
  `[Environment]::ProcessPath` (which is `Donut.Launcher.exe` in a hosted run).
  `Interpret` fails an exit-0 run with no result file.
- Live progress crosses the process boundary as lines: the worker writes to stdout,
  the launcher re-emits each line into the Information stream (never `ReadToEnd`),
  `AsyncJob.DrainStream` types each as a [LogLine](./ui-and-threading.md), and the
  `DcuProgress` parser drives the progress bar. Stderr drains on its own task so a
  full pipe cannot wedge the child.
- `ExecutionService` remains a worker-side god-class by choice; its transport rules
  are accreted regression fixes. Revisit the agreed decomposition (PsExecTransport /
  DcuPhases / InventoryProbe / DiskPhases / ResolvePhase / ArtifactCopy) when
  feature work next lands there.

## The fast resolve lane

Per-host IP resolves skip the pool entirely (`ResolveProcessJob` +
`ResolveWorker.ps1`):

- A slim, class-free child spawned via `Process.Start` — no pool slot, no runspace
  (~1–2 s vs the classic worker's ~2.5–5 s) — capped at 4 concurrent with a FIFO
  overflow queue.
- The verdict rides a result file, never redirected pipes. File-absent-after-exit is
  the `ProcessFault` signal: it retries that host once on the classic worker path,
  and 3 consecutive faults latch the lane off for the session.
- DC discovery (`Warm`, needs the AD module) and the identity check (`Name`, DCOM
  CIM) stay on the worker path.

## Two pools: worker and interactive

`RunspaceManager` opens two pools, because they starved each other when shared — a
fleet-wide scan pinned every runspace for minutes while a Lens lookup's
`BeginInvoke` never dispatched:

- The worker pool, sized to `throttleLimit` — what `AsyncJob` borrows from.
- A fixed interactive pool (`InteractiveSize = 4`) for `PoolScriptJob` scripts a
  user is waiting on: AD search, the Lens broker, unlock, the startup task. Four
  because the finder fans out one job per forest and the default is four.
- Both pools are `min = max`; if the interactive pool fails to open,
  `GetInteractivePool` degrades to the worker pool rather than failing the app.

Fanning work across the interactive lane must beat its own overhead — **the bar is
150 ms** (the agent serve loop's pass). The Lens owner lookup is one batched request
for this reason, and the AD search debounce/poll stay at 100/60 ms; raise them only
on log evidence (fan-out count and `(superseded)` markers are logged).

Interactive lookups carry their own deadline: `FinderPresenter.LensDeadline` (90 s,
deliberately longer than the in-worker timeouts so they report the real reason)
retires a lookup that never lands, and the completion branch removes the job from
`LensJobs` before touching the view-model.

## Pool script jobs

`PoolScriptJob` pins the rules for non-worker pool jobs:

- Never `Dispose()` a running pipeline (blocks the UI thread) — `BeginStop` and reap
  on a timer.
- Never pass `BeginStop` a scriptblock callback (fires on a runspace-less thread
  where any scriptblock throws).
- Envelopes stay hashtables (`@{ Ps; Handle }`) so each poll loop attaches its own
  per-job state.

## The pool warm

At startup `ResolutionCoordinator.WarmPool` runs `RemoteWorker.ps1` in
`Mode='WarmRunspace'` once per pool runspace behind a barrier. The rules, each a
guarded regression fix:

- **One graph compile in flight at a time.** The coordinator warms serially —
  submit a shell, wait, then the next. Serialization is mandatory, not an
  optimization.
- **One real worker pass per runspace, nothing more.** No superset graph warm; the
  AD/Lens graphs warm organically via the deferred finder warms
  (`HomePresenter.StartDeferredWarms`).
- **The first-use exercises are load-bearing** (localhost DNS/TCP/CIM, plus the
  pure-CPU `WarmScanLaunchPath`) — never reduce them to imports, and never add
  anything unproven under the barrier.
- **The barrier stops the waiting, never the work.** A shell that misses the 30 s
  deadline (`WarmTimeoutSeconds`) is parked still running — never `Dispose()`d,
  `Stop()`ped, or async-stopped. The pool max is raised by the parked count,
  `ReapWarmShells` harvests late finishers and returns the capacity, and only a
  truly wedged shell keeps its replacement. The "finished late (N s)" vs nothing
  split in the log is the slow-vs-wedged diagnostic.
- The DC warm is submitted first — it is the keystone every resolve gates on.

Guards: `RunspaceWarmCoverage.Tests.ps1` (static rules),
`tests/Integration/WarmPoolBarrier.Tests.ps1` (lapse path, heal, reap), and
`tests/Integration/StartupResolveSmoke.Tests.ps1` (the real scripts terminate).

The warm's original purpose — pre-compiling the worker graph into pool runspaces —
is vestigial now that children compile their own. It stays for the first-use
exercises; any shrink is a field-verified investigation, not a cleanup.

## ThreadPool floor

`RunspaceManager.Initialize` raises the .NET ThreadPool floor
(`SetMinThreads(max(16, max*2))`) as the first statement before any pool is created
— pool dispatch and completion callbacks run on ThreadPool threads, and the default
floor starves them at startup. Recognize a recurrence: stall heartbeats and the
barrier-lapse warning log `threadpool: N worker / M IOCP free`; ~0 free with idle
runspaces is the fingerprint. Guards: `RunspaceManager.Tests` reads the floor back;
`AsyncJob.LogStallHeartbeat` carries a latched one-shot runtime bump.

## Startup staging

Only the warm shells + the DC warm touch the pool at boot. The finder/Lens warms
and the startup-task heal defer until the DC warm completes
(`HomePresenter.StartDeferredWarms`, 90 s fallback; `DonutApp.ps1` defers
`ApplyStartupTask` 120 s). Never add pool work to the boot window.

No live hashtable crosses the runspace boundary — `Settings` and `Options` are
deep-cloned on the UI thread at prep time (`RemoteServices.BuildWorkerArgs`;
`AppConfig.DeepClone` is cycle-guarded).

## Reading the AD search breadcrumb

Each finder leg logs four spans that sum to its total:

```
AD search forest-d 'dan': 539ms (queue 18, search 205, rows 3, notice 313), 10 hit(s)
```

| Span | Covers | A large value points at |
|---|---|---|
| `queue` | dispatch → the worker's first line | pool slot wait, or a `using module` compile because the warm missed that runspace |
| `search` | `ActiveDirectoryService.Search` | the directory itself — compare against `tools\Measure-AdSearch.ps1` |
| `rows` | the rest of the worker | `MapRow` plus building the result objects |
| `notice` | worker done → `PollSearch` sees it | poll granularity and cross-runspace marshalling |

Read `notice` across a whole fan-out, not one line at a time — a straggler forest
legitimately waits out one dropdown render plus one poll tick (~90–120 ms). The
dropdown renders once per poll tick and logs `AD dropdown render: N drawn of M
pooled in Xms`, so render cost is visible instead of hiding inside somebody's
`notice`.

## Warm-shell forensics

- Each barrier shell carries a `warm-N` tag in the worker's `HostName` argument, so
  concurrent warm passes stay distinguishable in `Donut.log` (`[warm-3] Worker
  up:`). The DC-warm AsyncJob keeps its empty `HostName` — `CompleteResolve`'s
  DC-warm sentinel.
- A lapsed shell is logged per-shell via `DescribeShell` (indexed stream reads only
  — enumerating a live `Streams.Error` while the worker appends races);
  `ReapWarmShells` re-dumps parked-shell state at most once a minute.
- A warm whose pipeline completed with errors logs at ERROR and is counted apart:
  `Pre-warmed N of M runspace(s) (K completed with errors).`

## Logging and diagnostics

- **Startup provenance stamp:** `BuildProvenance::Stamp` logs the git short SHA
  (+`dirty`) on clones, plus pwsh/CLR versions, machine name, and OS build. On an
  MSI install the stamp reads `unknown` and the build is identified by the
  uninstall key's `DisplayVersion`.
- **Debug-log gate:** `[DEBUG]` breadcrumbs are opt-in (`debugLogging`, default
  off; `Start-Donut -DebugLog` forces a session on). INFO/WARN/ERROR always flow;
  workers receive the parent's effective state per job. Any field diagnosis needs
  the gate on **before** reproducing — the wedge forensics live at DEBUG.
- **`LogService` uses lock-free atomic appends** (Append mode, ReadWrite sharing,
  one line per `Write`). It deliberately holds no lock: logging must never be able
  to block the app it serves.
- **Every `AsyncJob` gets the real logger:** the 3-arg constructor is mandatory in
  production (`AsyncJobLoggerCoverage.Tests.ps1`); the 2-arg form coalesces to
  `NullLogService` and is for tests only.
- **Every `AsyncJob` has a stall heartbeat:** a WARN at 90 s then every 5 min, with
  the pool's free/max count. `0 free` means queued behind busy runspaces; free > 0
  means the worker itself has not returned. Long scans legitimately cross it — the
  heartbeat is evidence, not an error.
- **Dispatcher watchdog:** warns when the 250 ms tick gap exceeds the threshold,
  with GC gen deltas (gen2 > 0 = blocking GC; `+0/+0/+0` = loader lock or
  synchronous UI-thread work). `MainPresenter` calls `Reset()` right before
  `Application.Run`, so startup time is never charged to the first tick.
- **Class methods are statically checked for unassigned variables**
  (`ClassVariableCoverage.Tests.ps1`) — PowerShell only raises the error when the
  method actually runs.
- Every resolve step leaves its DEBUG breadcrumb **before** the call — a hooked
  native connect never returns, so only a pre-call line can identify it.
