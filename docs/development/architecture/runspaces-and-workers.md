---
title: Runspaces and workers
description: The job pool, worker process isolation, the warm rules, and the diagnostics that keep them honest.
---

How DONUT runs background work: a runspace pool for throttling, child `pwsh`
processes for isolation, and a set of hard-won warm/staging rules. Most rules on
this page are guarded regression fixes; the tests named next to them enforce the
rules statically.

![Runspaces and workers class diagram](/diagrams/class_runspaces.svg)

*Source: [`class_runspaces.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_runspaces.puml)*

## Worker process isolation

Workers run as isolated child processes. This resolved the DC-warm/scan saga:

- Running the worker class graph in-process on pool runspaces is fundamentally
  unsafe: 2+ runspaces cold-loading the `using module` graph concurrently deadlock
  on PowerShell's module-load lock, and even serial loads onto a second runspace
  hang. 64dbec8 only worked because ThreadPool starvation accidentally serialized
  execution.
- Each job therefore runs in its own child `pwsh` process (separate AppDomain).
  The pool stays for throttling (`throttleLimit`), but each runspace only runs a
  tiny launcher (no `using module`, so no class-load, no deadlock) that spawns
  `RemoteWorker.ps1` and returns its result.
- Responsibilities: `WorkerProcess` owns the isolation mechanics (args to temp
  file, launcher scriptblock, result-file to verdict); `AsyncJob` orchestrates the
  lifecycle; `RemoteWorker.ps1` reads `-ArgsFile` and writes `-ResultFile`.
  Validated at 8-way concurrency with zero deadlock.
- **Note:** the child executable is `WorkerProcess.FindPwsh()`, never
  `[Environment]::ProcessPath`. In a launcher-hosted run `ProcessPath` is
  `Donut.Launcher.exe` (PowerShell is hosted in-process); spawning it forked a
  second DONUT that bowed out via the single-instance guard - exit 0, no result
  file, which `Interpret` read as a silent success with a null result, wedging the
  caller. `Interpret` now fails exit-0 with no result, and `CompleteResolveCore`
  drops payloadless verdicts loudly.
- Live progress survives the process boundary: `RemoteWorker.ps1` sets
  `$InformationPreference='Continue'` so its dcu-tail `Write-Information` lines
  hit the child's stdout; the launcher reads that stdout line by line (never
  `ReadToEnd`) and re-emits each line into the pool runspace's Information
  stream. `AsyncJob.DrainStream` then types each line as a
  [LogLine](./ui-and-threading.md) carrying the stream's severity, and the
  `DcuProgress` parser drives the progress bar as before. Stderr is drained on a
  `ReadToEndAsync` task so a full pipe cannot wedge the child.
- Classes are not automatically available in new runspaces: the required class
  modules (`Models`, `Services`) are explicitly loaded into each runspace before
  execution.
- **`ExecutionService` split (deferred):** the worker-side god-class carries ~6
  concerns; the agreed target decomposition is PsExecTransport / DcuPhases /
  InventoryProbe / DiskPhases / ResolvePhase / ArtifactCopy. Deferred because its
  transport rules are accreted regression fixes, the 770-line test file couples to
  its seams, and every extra `using module` slows every child. Revisit when
  feature work next lands there.

## The fast resolve lane

Per-host IP resolves skip the pool entirely (`ResolveProcessJob` +
`ResolveWorker.ps1`):

- The classic path paid a full worker child (pwsh cold start + the ~12-module
  class-graph compile, ~2.5-5 s) for one `Resolve-DnsName -Server $dc` and one
  bounded TCP-135 probe - and held a pool runspace for the child's life, so
  resolves queued for minutes behind running scans.
- The fast lane spawns a slim, class-free `ResolveWorker.ps1` directly via
  `Process.Start` (no pool slot, no runspace, no ThreadPool dispatch; ~1-2 s),
  capped at 4 concurrent with a FIFO overflow queue.
- The verdict rides a result file, never redirected pipes (the proven wedge
  surface). File-absent-after-exit is the `ProcessFault` signal: crash/kill/
  timeout retries that host once on the classic worker path, and 3 consecutive
  faults latch the lane off for the session (worst case = the old behavior). A
  wedged child is `Kill()`-able - the recovery a wedged pipeline never had.
- DC discovery (`Warm`, needs the AD module) and the identity check (`Name`,
  DCOM CIM) stay on the worker path.
- **Note (deferred upgrade):** a pinned resolver (`-Serve` switch, JSON-lines
  requests on stdin, LensAgent-style supervision) would save ~1-1.5 s per resolve.
  Build it only if field logs show resolve wall time still gating something a
  user watches; the supervision complexity is not worth it until proven needed.

## Two pools: worker and interactive

`RunspaceManager` opens two pools:

- The worker pool, sized to `throttleLimit` - what `AsyncJob` borrows from.
- A small fixed interactive pool (`InteractiveSize = 4`) that `PoolScriptJob`
  uses for the in-process scripts a user is waiting on: AD search, the Lens
  broker, unlock, the startup task. Four, because the AD finder's fan-out is one
  job per configured forest and the default is four; at 3 the last forest queued
  on every search, not just under contention.

They are separate because they starved each other: every worker job holds its
runspace for the whole child-process lifetime, `RunAll` starts one per host with
no cap, and with `min = max` a fleet-wide scan pinned every runspace for
minutes. A Lens lookup submitted meanwhile had its `BeginInvoke` queued and
never dispatched, and the detail pane sat on "Looking up directory + SCCM..."
forever. The distinction was documented in `PoolScriptJob` before it was
enforced; it is now pool identity, not convention.

- The interactive pool is also `min = max` (idle cleanup only disposes above
  the minimum, so a lower floor would let warmed runspaces die and cold-load).
- The ThreadPool floor covers both pools, and the interactive pool warms
  organically through the deferred finder warms, as before.
- If it fails to open, `GetInteractivePool` degrades to the worker pool rather
  than failing the app - the pre-split behaviour.

### Concurrency has to beat its own overhead

The interactive lane is small and shared, so fanning work across it is only worth
it when a single leg is slower than the machinery around it. **The bar is 150 ms**,
the agent serve loop's pass. Two decisions came out of applying it:

- **The Lens owner lookup is one batched request, not one per machine.** The agent
  answers it inline on that 150 ms loop, so N requests would cost N passes plus N
  files, N AES round trips and N parent polls - slower than resolving them back to
  back, while holding N of the four runspaces. Parent-side fan-out against a
  serially-served agent buys no throughput at all.
- **The bar cuts both ways, and it caught a change of its own.** The AD search
  debounce was raised 100 -> 250 ms and its poll 60 -> 150 ms, on the theory that
  typing re-fanned-out and the superseded shells held the lane (`AbortSearch`
  cancels through `BeginStop`, which is asynchronous). Both are back at 100/60:
  - The debounce charged every completed search a flat +150 ms - *above* the bar
    the same change set - to avoid a cost that was argued rather than measured.
  - The poll raise was simply wrong. `SearchPollTimer` starts only when a fan-out
    begins and stops when the last leg lands, so it never ticks while idle and a
    fast tick costs nothing; a slow one is dead time before the dropdown paints,
    and it inflates the per-forest elapsed, which is taken when the poll *notices*
    rather than when the job finished.

  Raise the debounce again only on log evidence: the fan-out count per search and
  the `(superseded)` marker are logged so the case can be made from numbers.

**Cancelling the remaining forests once one answers is not on the table.** The
forests hold disjoint populations and `RenderDropdown` applies no cap and no
relevance ranking, so an early stop would drop real people from the result rather
than trimming duplicate work - and make *which* people depend on which forest won
the race, including the row `Enter` pre-selects. Cancel-on-supersede is the
legitimate form of that idea, and `AbortSearch` already does it.

Per-forest search times differ by forest and are stable, and the fan-out clearly earns
its keep: serial would be the sum of every forest against the slowest one in parallel.

### Reading the AD search breadcrumb

A total alone cannot separate the directory from the machinery around it, so each leg
logs the four spans that sum to it:

```
AD search forest-d.local 'dan': 539ms (queue 18, search 205, rows 3, notice 313), 10 hit(s)
```

| Span | Covers | A large value points at |
|---|---|---|
| `queue` | dispatch -> the worker's first line | pool slot wait, or a `using module` compile because the warm missed that runspace |
| `search` | `ActiveDirectoryService.Search` | the directory itself - compare against `tools\Measure-AdSearch.ps1` |
| `rows` | the rest of the worker | `MapRow` plus building the result objects |
| `notice` | worker done -> `PollSearch` sees it | poll granularity and cross-runspace marshalling |

`AdSearchWorker.ps1` emits its start ticks, `Search` elapsed and end ticks as a single
`AdTiming` record on the **Information** stream (the success stream is the typed row
contract, and Warning already carries forest failures); `PoolScriptJob.Start` stamps the
dispatch; `FinderPresenter.DescribeSearchTiming` does the arithmetic. Neither side of the
runspace boundary can see all four, and both run in the same process on the same clock so
there is no skew to correct. A leg with no record - superseded, or thrown - still logs its
total.

**Read `notice` across a whole fan-out, not one line at a time.** The first thing these
spans found was that all four forests finished within 27ms of each other while their totals
spread across 465ms - every bit of it in `notice`, because `PollSearch` re-rendered the
dropdown per landed leg on the UI thread. It now renders **once per tick**, after folding
every completed leg, and logs `AD dropdown render: N row(s) in Xms` so that cost is visible
instead of hiding inside somebody else's `notice`. Rendering per leg is the shape to watch
for: any UI-thread work inside a poll loop is charged to whichever job is unlucky enough to
be read next. See [AD query rules](./ad-queries.md) for the full numbers.

**A single render is still UI-thread work, so it still blocks the stragglers.** With the
per-leg renders gone, `prod` finished its own work at 293ms and was not read until 673ms -
it sat behind one 204ms render of the three forests that landed first. That render cost was
~3ms a row and linear (2 rows 10ms, 20 rows 51ms, 45 rows 164ms, 55 rows 178ms), and it was
neither WPF virtualization (the ListBox has a `MaxHeight`, so it virtualizes) nor PowerShell
closures (measured at ~0.2ms a row). It was `SearchResults.Clear()` followed by an `Add` per
row: **every `Add` on a bound `ObservableCollection` raises `CollectionChanged` and
invalidates the ListBox layout**, so a 55-row render was 55 layout passes. `RenderDropdown`
now builds the list first and hands it over in one `Set`, so the ListBox does a single reset.
Never populate a bound collection item by item on a path a user is waiting on.

Measured after the swap (log line `AD dropdown render: N drawn of M pooled in Xms`): the
linear term is gone - ~55-70ms roughly flat whether 6 hits pooled or 72, with tiny renders
(1-2 rows) at ~11ms. That is the fixed cost of the pipeline sorts, the view-model build and
the single ListBox reset, and it sits **under the 150ms bar**, so it stays. The first render
of a session runs ~200ms - the popup's visual tree instantiates on its first open, plus
first-call JIT of the ranking path - and is a one-time cost, not a leak. The straggler
forest still waits out one render plus one poll tick (~90-120ms of its `notice`); that is
the streaming trade-off, not a defect.

Interactive lookups also carry their own deadline. Pool separation stops the
starvation, but no poll loop should be able to wait forever:
`FinderPresenter.LensDeadline` (90 s, deliberately longer than
`PersonLensService.TimeoutSec` and the agent's 45 s `Wait-Job` so in-worker
timeouts still report the real reason) retires a lookup that never lands and
applies a `PersonLens.FromError` bundle. The completion branch is guarded too:
it removes the job from `LensJobs` before touching the view-model, so an
exception past that point cannot leave the pane loading with nothing left to
retry.

## Pool script jobs

Non-worker pool jobs (AD search, Lens broker, unlock, startup task) share one
Core helper - `PoolScriptJob` - for start / complete / async-stop / reap on the
interactive pool instead of hand-rolled copies. The rules it pins:

- Never `Dispose()` a running pipeline: it blocks the UI thread. `BeginStop` and
  reap on a timer instead.
- Never pass `BeginStop` a scriptblock callback: it fires on a runspace-less
  thread where any scriptblock throws.
- Envelopes stay hashtables (`@{ Ps; Handle }`) so each poll loop attaches its own
  per-job state.

## Warm compile serialization

The actual DC-warm/scan regression (fixed 2026-07-23):

- Compiling a `using module` class graph in 4+ runspaces at once deadlocks on
  PowerShell's module-load lock (measured threshold: 2-3 concurrent are fine, 4+
  hang; reproduced end-to-end). The wedged compiles hold the lock, so every later
  class operation - even in a runspace that already compiled - blocks behind them.
- This is why field logs showed a scan reach `Worker up: JobType=Scan` then hang
  at the next class call: everything was queued behind the deadlocked warm
  compiles. The ThreadPool floor fix exposed it - once dispatch stopped starving,
  all 8 warm passes finally ran at once and deadlocked.
- **The fix:** `WarmPool` warms one runspace at a time - submit a shell, wait for
  it, then the next - so only one graph compile is ever in flight. The first pass
  compiles (~0.5 s) and primes the process module-analysis cache; the rest reuse
  it (~30 ms each).
- **Note:** priming does not make concurrent compiles safe - the deadlock is on
  the lock itself, not a cache miss - so serialization is mandatory, not an
  optimization. `RunspaceWarmCoverage.Tests` guards it: the coordinator must wait
  per shell, never accumulate all handles before waiting.

## The pool warm

One real worker pass per runspace - the 64dbec8 recipe, nothing more:

- At startup `ResolutionCoordinator.WarmPool` runs `RemoteWorker.ps1` in
  `Mode='WarmRunspace'` once per pool runspace (concurrently, behind a barrier):
  script compile, real pipeline construction, `WarmRuntimeAssemblies`'s localhost
  DNS/TCP/CIM exercises, and `WarmScanLaunchPath` (the CPU half of the scan
  launch: dcu-cli arg build, remote-script build + encode).
- Pre-loading a module graph alone is not enough. When a runspace's first
  `RemoteWorker.ps1` execution happened on a live job, that job wedged silently -
  the startup DC discovery never logged a line and every resolve/inventory
  quietly no-oped (the machine-list regression). The same first-execution rule
  applies per code path: a live DCU scan once wedged on the first-ever
  `InvokePsExec` in the process.
- **The barrier must never carry a superset graph warm.** A `Warm-Runspace.ps1`
  (since removed) that loaded the full AD + Lens graph and imported the binary
  CIM/ScheduledTasks modules per runspace shipped on 07-20; 8 concurrent copies
  contended the process-wide module-analysis and CLR loader locks, the shells
  stopped fitting the 30 s barrier at all (`Pre-warmed 0 of 8`), and every
  feature queued behind a starved pool. The AD/Lens graphs warm organically via
  the deferred finder warms instead (`HomePresenter.StartDeferredWarms`).
- **The first-use exercises are load-bearing - never reduce them to
  imports/loads.** A loads-only warm shipped once and the first live resolve-IP
  and disk-scan jobs - whose opening act is exactly a first DNS/socket connect -
  stopped completing. The inverse also stands: nothing unproven goes under the
  barrier (the loopback port-445 probe was in no known-good build and stays out;
  `WarmScanLaunchPath` remains pure CPU).
- Wedge risk is carried by the barrier's design, never by removing exercises. The
  barrier (default 30 s, `WarmTimeoutSeconds`) stops the waiting, never the work:
  a shell that missed the deadline must not be `Dispose()`d, `Stop()`ped, or
  async-stopped (each shipped a regression - the first two hang on a wedged
  pipeline; the async stop destroyed warms that were merely slow, e.g. first-run
  AV/AMSI scanning of the module graph). The shell is parked still running, the
  pool max is raised by the parked count so real jobs always find a runspace, and
  `ReapWarmShells` harvests each late finisher - its runspace lands fully warmed
  and one unit of raised capacity is returned, so the pool converges on the
  configured throttle. Only a truly wedged shell keeps its replacement capacity.
- The late/never reap split in the log ("finished late (N s)" vs nothing) doubles
  as the slow-vs-wedged diagnostic.
- `HomePresenter.Initialize` submits the DC warm before the finder/Lens warms -
  the DC is the keystone every resolve gates on, so it must be first in line for
  a degraded pool.
- The starvation signature in `Donut.log`: the barrier-lapse warning,
  `Pre-warmed N of M` with `N < M`, `DC warm-up started (pool free: 0/...)`, and
  Resolve-job stall heartbeats with `0/... free`. Every resolve step leaves a
  DEBUG breadcrumb, logged **before** the call on purpose - a hooked native
  connect never returns, so only a pre-call line can identify it.
- Guards: `RunspaceWarmCoverage.Tests.ps1` (static rules: worker pass at the
  barrier, no superset warm, pure-CPU `WarmScanLaunchPath`, the exercises present,
  startup staging, the self-heal, park-and-reap with no Stop of any kind);
  `tests/Integration/WarmPoolBarrier.Tests.ps1` (the lapse path returns promptly,
  heals capacity, dispatches while parked, reaps back to the throttle); and
  `tests/Integration/StartupResolveSmoke.Tests.ps1` (the real warm + resolve
  scripts always terminate).
- **Note:** the warm's original purpose - pre-compiling the worker class graph
  into pool runspaces - is vestigial now that children compile their own graph.
  The warm stays anyway: it carries the load-bearing first-use exercises, and the
  compile serialization + ThreadPool floor are guarded regression fixes. Any
  shrink is a separate field-verified investigation, not a cleanup.

## Warm-shell forensics

- Each barrier shell carries a `warm-N` tag riding in the worker's `HostName`
  argument (`PrepareWarmRunspace([string]$tag)`), so 8 concurrent warm passes
  stay distinguishable in `Donut.log` (`[warm-3] Worker up:`). The tag is for
  warm shells only - the DC-warm AsyncJob keeps its empty `HostName`, which
  `CompleteResolve` uses as its DC-warm sentinel.
- The barrier never discards evidence: a shell that misses the deadline is logged
  per-shell via `DescribeShell` (indexed stream reads only - enumerating a live
  `Streams.Error` while the worker appends is the "Collection was modified"
  race); `ReapWarmShells` re-dumps parked-shell state at most once a minute.
- A warm whose pipeline completed with errors logs at ERROR and is counted apart:
  `Pre-warmed N of M runspace(s) (K completed with errors).` Before this, an
  errored warm counted as warmed and the log showed nothing at all.

## ThreadPool floor (pool-dispatch starvation)

Confirmed regression, fixed 2026-07-23:

- A `RunspacePool` dispatches pipelines and fires completion callbacks on .NET
  ThreadPool threads, whose floor defaults to `Environment.ProcessorCount`. At
  startup the app opens 8 warm runspaces at once, saturating that floor; further
  dispatch waits on the ThreadPool's slow ~1-thread/second injection.
- The field signature is misleading: the pool reports runspaces idle/Available
  while every warm and the DC-resolve job sit at `state=Running` for minutes -
  queued and never dispatched, not wedged inside a runspace (a wedged pipeline
  reads Busy). `tools/Get-DonutRunspaceStacks.ps1` against the live app pinned it:
  every runspace `Availability=Available` while the resolve job ran past 391 s.
- **The fix:** `RunspaceManager.Initialize` raises the floor with
  `ThreadPool::SetMinThreads(max(16, max*2))` as the first statement **before**
  `CreateRunspacePool`, so every pool-creation path gets it.
- How to recognize it again: the stall heartbeat and the barrier-lapse warning
  both log `threadpool: N worker / M IOCP free`; ~0 free with idle runspaces is
  the fingerprint.
- Guards: `RunspaceManager.Tests` reads the floor back; `RunspaceWarmCoverage.Tests`
  statically asserts `SetMinThreads` precedes `CreateRunspacePool`; and
  `AsyncJob.LogStallHeartbeat` carries a latched runtime backstop - one
  `SetMinThreads` bump if a stall ever shows the signature again (idle runspaces
  + at most 1 free worker thread), so a busy-runspace stall never trips it.

## Startup staging

Only the warm shells + the DC warm touch the pool at boot:

1. Warm shells and the DC warm are submitted at startup.
2. The finder/Lens warms and the startup-task heal are deferred until the DC warm
   completes (`HomePresenter.StartDeferredWarms`, 90 s fallback timer;
   `DonutApp.ps1` defers `ApplyStartupTask` 120 s).

- The stampede that accreted before this - one live-LDAP finder warm per forest,
  the Lens agent bring-up, and the startup-task heal, all inside the same two
  seconds - contended the process-wide module-analysis/loader locks and the
  WMI/Task Scheduler services against the warm barrier, and pool jobs froze for
  minutes inside pure-CPU segments (the `+0/+0/+0` GC watchdog signature). Never
  add pool work to the boot window; defer it behind the DC warm.
- **Note:** no live hashtable may cross the runspace boundary - `Settings` and
  `Options` are deep-cloned on the UI thread at prep time
  (`RemoteServices.BuildWorkerArgs`), and `AppConfig.DeepClone` is cycle-guarded.
  `RunspaceWarmCoverage.Tests.ps1` guards the staging statically.

## Logging and diagnostics

- **Startup provenance stamp:** right after `DONUT starting up.`,
  `BuildProvenance::Stamp` logs the git short SHA (+`dirty`) on clones - falling
  back to a `version.txt` in the data root - plus pwsh/CLR versions, machine
  name, and OS build, so every `Donut.log` is attributable to an exact commit.
  **Note:** nothing writes that `version.txt`. No build step, installer script or
  launcher code produces it, so on an MSI install the stamp reads `unknown` and
  the build is identified by the uninstall key's `DisplayVersion` instead. It is
  an optional hand-placed override, not a packaging artifact.
- **Debug-log gate:** `[DEBUG]` breadcrumbs are opt-in (`debugLogging` setting,
  default off; `Start-Donut -DebugLog` forces a session on without persisting).
  INFO/WARN/ERROR always flow; the toggle applies live, and workers receive the
  parent's effective state per job. **Note:** any field diagnosis needs
  `-DebugLog` (or the toggle) on before reproducing - the wedge forensics all
  live at DEBUG.
- **`LogService` is thread-safe via lock-free atomic appends** - every writer
  opens `Donut.log` in Append mode with ReadWrite sharing and emits one line per
  `Write` call, which the kernel serializes. It deliberately holds no lock: an
  earlier named-mutex design collapsed under its own concurrency (2 s waits per
  writer, dispatcher blocks, an infinite warning storm, dropped lines, warms
  missing the 30 s barrier from logging cost alone). Logging must never be able
  to block the app it serves.
- **Every `AsyncJob` gets the real logger:** the 3-arg constructor is mandatory
  for production call sites (`AsyncJobLoggerCoverage.Tests.ps1` enforces it). The
  2-arg form coalesces to `NullLogService` and is for tests only - it once made
  every job failure invisible in `Donut.log`.
- **Every `AsyncJob` has a stall heartbeat:** `Poll()` logs a WARN once a job has
  run 90 s without completing, then every 5 min, including the pool's free/max
  count. `0 free` means queued behind busy or stuck runspaces; free > 0 means the
  worker itself has not returned. Long scans legitimately cross the threshold -
  the heartbeat is evidence, not an error.
- **Dispatcher watchdog:** `DispatcherWatchdog` warns when its 250 ms tick gap
  exceeds the threshold and appends the GC gen0/1/2 deltas (gen2 > 0 = blocking
  GC; +0/+0/+0 = loader lock or synchronous UI-thread work). The first
  measurement after `Start()`/`Reset()` is discarded and `MainPresenter` calls
  `Reset()` right before `Application.Run`, so pre-pump startup time is never
  charged to the first tick.
- **Class methods are statically checked for unassigned variables:**
  `ClassVariableCoverage.Tests.ps1` walks every class method's AST, because
  PowerShell only raises "Variable is not assigned in the method." when the
  method actually runs (a missed rename once loaded clean and failed in the
  field).
- **WizTree CSV is parsed streaming:** `WizTreeCsv.ParseTopFoldersFromFile` reads
  line by line on the pool thread; the earlier `-Raw` + `-split` +
  `ConvertFrom-Csv` pass materialized a giant string, a line array, and a
  `PSObject` per row, and the resulting gen-2 GCs suspended the UI thread right
  as a disk scan finished.
