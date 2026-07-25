---
title: Implementation notes
description: How the design handles remote execution, threading, de-elevation, configuration, and PowerShell's constraints.
---

How the design handles the constraints of remote execution, threading, and packaging.

## Parallel execution (runspaces)

The original tool used PowerShell runspaces for parallel execution; DONUT keeps that
model.

- **Workers run as isolated child processes (process isolation) — the resolution to
  the whole DC-warm/scan saga.** Running the worker class graph *in-process* on pool
  runspaces is fundamentally unsafe: 2+ runspaces cold-loading the `using module` graph
  concurrently deadlock on PowerShell's module-load lock, and even serial loads onto a
  second runspace hang. 64dbec8 only worked because ThreadPool starvation accidentally
  serialized execution. The fix is DONUT's *original* (first-commit) model: each job
  runs in its own **child `pwsh` process** (separate AppDomain), so parallel workers
  never share the class-load lock. The pool stays — but each runspace now runs a tiny
  **launcher** (no `using module`, so no class-load, no deadlock) that spawns
  `RemoteWorker.ps1` as a child and returns its result. Concurrency is still throttled
  by the pool's `throttleLimit`; isolation comes free from the process boundary.
  `WorkerProcess` owns this one concern (args → temp file, launcher scriptblock,
  result-file → verdict); `AsyncJob` just orchestrates the lifecycle; `RemoteWorker.ps1`
  reads `-ArgsFile` and writes `-ResultFile`. Validated at 8-way concurrency with zero
  deadlock. **Live progress** survives the process boundary: `RemoteWorker.ps1` sets
  `$InformationPreference='Continue'` so its dcu-tail `Write-Information` lines hit the
  child's stdout, and the launcher reads that stdout *line-by-line* (not `ReadToEnd`),
  re-emitting each line into the pool runspace's Information stream — where
  `AsyncJob.DrainStream` → `job.Logs` → the existing `DcuProgress` parser drives the
  `ThinProgressBar` exactly as before. Stderr is drained on a `ReadToEndAsync` task so a
  full pipe can't wedge the child. *(The pool warm's original purpose — pre-compiling the
  worker class graph into pool runspaces — is vestigial for worker jobs now that children
  compile their own graph. The warm pass stays anyway: it carries the load-bearing
  first-use exercises (removing them regressed the first resolve/disk-scan, 07e524b), and
  the compile serialization + ThreadPool floor are guarded regression fixes. Any shrink is
  a separate field-verified investigation, not a cleanup.)*
- **Classes in runspaces:** PowerShell classes are not automatically available in new
  runspaces, so the required class modules (`Models`, `Services`) are explicitly
  loaded into each runspace before execution.
- **Warm compile serialization — the actual DC-warm/scan regression (fixed
  2026-07-23).** Compiling a `using module` class graph in **4+ runspaces at once
  deadlocks** on PowerShell's module-load lock (measured threshold: 2–3 concurrent
  are fine, 4+ hang; reproduced end-to-end). The wedged compiles *hold* the lock, so
  every later class operation — even in a runspace that already compiled — blocks
  behind them. This is why the field logs showed a scan reach `Worker up:
  JobType=Scan` and then hang at the next class call, and a second Resolve wedge right
  after `Config built`: they were all queued behind the deadlocked warm compiles.
  The ThreadPool floor fix *exposed* this — once dispatch stopped starving, all 8
  warm passes finally ran at once and deadlocked. **The fix:** `WarmPool` warms **one
  runspace at a time** — submit a shell, wait for it, then the next — so only one
  graph compile is ever in flight. The first pass compiles (~0.5 s) and primes the
  process module-analysis cache; the rest reuse it (~30 ms each), so the whole warm
  is a second or two (`Pre-warmed 8 of 8` in ~0.5 s, vs a 30 s barrier lapse before).
  Priming does **not** make concurrent compiles safe — the deadlock is on the lock
  itself, not a cache miss — so serialization is mandatory, not an optimization.
  `RunspaceWarmCoverage.Tests` guards it: the coordinator must wait per shell, never
  accumulate all handles before waiting.
- **Pool warm = ONE real worker pass per runspace — the 64dbec8 recipe, nothing
  more:** at startup `ResolutionCoordinator.WarmPool` runs `RemoteWorker.ps1` in
  `Mode='WarmRunspace'` once per pool runspace (concurrently, behind a barrier):
  script compile, real pipeline construction, `WarmRuntimeAssemblies`'s localhost
  DNS/TCP/CIM exercises, and `WarmScanLaunchPath`. Pre-loading a module
  graph alone is not enough: when a runspace's first `RemoteWorker.ps1` execution
  happened on a live job, that job wedged silently — the startup DC discovery never
  logged a line, `HostResolver` never got an active DC, and every resolve/inventory
  quietly no-oped (the machine-list regression). The same first-execution rule
  applies *per code path*: a live DCU scan once wedged between "Starting preliminary
  scan" and the psexec launch on the first-ever `InvokePsExec` in the process, so the
  warm also pre-executes the CPU half of the scan launch path (dcu-cli arg build,
  remote-script build + encode). **The barrier must never carry a superset graph
  warm.** A `Warm-Runspace.ps1` that loaded the full AD + Lens graph and imported
  the binary CIM/ScheduledTasks modules per runspace shipped on 07-20 alongside the
  agent-AD work; 8 concurrent copies contend the **process-wide** module-analysis
  and CLR loader locks, the shells stopped fitting the 30 s barrier at all
  (`Pre-warmed 0 of 8`), and every feature queued behind a starved pool. The
  AD/Lens graphs warm organically via the *deferred* finder warms instead
  (`HomePresenter.StartDeferredWarms`); a first mid-scan search on a runspace they
  have not reached may pay a one-time cold-load — a deliberate trade, revisit only
  with the barrier kept out of it. **The first-use exercises are load-bearing — do not
  reduce them to imports/loads.** A loads-only warm shipped once and the first live
  resolve-IP and disk-scan jobs — whose opening act is exactly a first DNS/socket
  connect — stopped completing on machines where the exercise-ful recipe (64dbec8
  through 36c7536) had worked for weeks. The inverse lesson also stands: nothing
  *unproven* goes under the barrier — the loopback port-445 probe (2292abe) was in
  no known-good build, coincided with the no-window incident, and stays out;
  `WarmScanLaunchPath` remains pure CPU. Wedge risk from the exercises is carried
  by the barrier's design, never by removing them: `WarmPool`'s barrier (default 30 s,
  `WarmTimeoutSeconds`) **stops the waiting, never the work**: a shell that missed
  the deadline must not be `Dispose()`d or `Stop()`ped (both wait on the pipeline
  synchronously, and a wedged pipeline never yields — that hang shipped once,
  pre-window) and must not be async-stopped either (that shipped too, and it
  destroyed warms that were merely *slow* — first-run AV/AMSI scanning of the
  module graph pushes warms past the barrier — wasting the work just before it
  finished). Instead the shell is parked *still running*, the pool max is raised
  by the parked count so real jobs always find a runspace, and the job pump's
  `ReapWarmShells` harvests each late finisher: its runspace lands fully warmed
  and one unit of the raised capacity is given back, so the pool converges on the
  configured throttle. Only a truly wedged shell keeps its replacement capacity —
  there, the raise is what keeps the app alive. The late/never reap split in the
  log ("finished late (N s)" vs. nothing) doubles as the slow-vs-wedged
  diagnostic. `HomePresenter.Initialize` submits the DC warm *before* the
  finder/Lens warms — the DC is the keystone every resolve gates on, so it must be
  first in line for a degraded pool. The starvation signature in `Donut.log`: the
  barrier-lapse warning, `Pre-warmed N of M` with `N < M`, `DC warm-up started
  (pool free: 0/…)`, and Resolve-job stall heartbeats with `0/… free`. Beyond that,
  every resolve step leaves a DEBUG breadcrumb — "Worker up" (graph compiled),
  "querying AD", per-DC "probing", "DNS: resolving … via DC", port probes'
  "connecting to 'host':port", warm-exercise "Warm: exercising …", and "verdict
  received" — so a stalled resolve's *last* log line names the wedged step. The
  probe/exercise breadcrumbs log **before** the call on purpose: a hooked native
  connect never returns, so only a pre-call line can identify it.
  `RunspaceWarmCoverage.Tests.ps1` guards the static rules (worker pass at the
  barrier, no superset warm; `WarmScanLaunchPath` pure CPU; the DNS/TCP/CIM
  exercises present in `WarmRuntimeAssemblies`; startup staging; the self-heal;
  park-and-reap with no Stop of any kind);
  `tests/Integration/WarmPoolBarrier.Tests.ps1` proves the lapse path returns
  promptly, heals capacity, dispatches work while shells are parked, and reaps
  late warms back to the configured throttle; and
  `tests/Integration/StartupResolveSmoke.Tests.ps1` runs the real warm + resolve
  scripts on a real pool and asserts they always terminate (the "`Started Resolve
  job.` then silence" regression family).

- **Warm-shell forensics.** Each barrier shell carries a `warm-N` tag that rides in
  the worker's `HostName` argument (`PrepareWarmRunspace([string]$tag)`), so the 8
  concurrent warm passes stay distinguishable in `Donut.log` (`[warm-3] Worker up:`).
  The tag is for warm shells only — the DC-warm AsyncJob keeps its empty `HostName`,
  which `CompleteResolve` uses as its DC-warm sentinel. The barrier never discards
  evidence: a shell that misses the deadline is logged per-shell
  (`Warm shell parked at barrier lapse: warm-N state=… hadErrors=… errors=[…]`) via
  `DescribeShell` (indexed stream reads only — enumerating a live `Streams.Error`
  while the worker appends is the "Collection was modified" race), `ReapWarmShells`
  re-dumps parked-shell state at most once a minute, and a warm whose pipeline
  completed **with errors** now logs at ERROR and is counted apart:
  `Pre-warmed N of M runspace(s) (K completed with errors).` — before this, an
  errored warm counted as warmed and the log showed nothing at all. AsyncJob's
  stall heartbeat likewise reports `state:` and `firstError=` for the wedged shell.

- **ThreadPool floor (pool-dispatch starvation) — CONFIRMED regression, fixed
  2026-07-23.** A `RunspacePool` dispatches pipelines and fires their completion
  callbacks on **.NET ThreadPool** threads, whose floor defaults to
  `Environment.ProcessorCount`. At startup the app opens 8 warm runspaces at once
  (each compiling the full `using module` graph), which saturates that floor;
  further dispatch/completion callbacks then wait on the ThreadPool's slow
  ~1-thread/second injection. The field signature is unmistakable and misleading:
  the pool reports runspaces *idle/Available* while every warm and the DC-resolve
  job sit at `state=Running` for minutes — they are queued and never dispatched,
  not wedged inside a runspace (a wedged pipeline would read *Busy*). The identical
  scripts complete in ~2 s in the headless harness, whose process has nothing else
  touching the ThreadPool. **How it was pinned:** the field diagnostics
  (`tools/Get-DonutRunspaceStacks.ps1` against the live app) showed every pool
  runspace `Availability=Available` while the resolve job reported `state=Running`
  past 391 s — proving *queued, not wedged*. Raising the floor restored IP
  resolution **and** disk scan on the domain test machine that same day.
  **The fix:** `RunspaceManager.Initialize` raises the floor with
  `ThreadPool::SetMinThreads(max(16, max*2))` as the first statement **before**
  `CreateRunspacePool`, so *every* pool-creation path (the explicit startup call,
  the lazy `GetPool` default, the warm) gets it and dispatch never waits on thread
  injection. **How to recognize it again:** the stall heartbeat and the warm
  barrier-lapse warning both log `threadpool: N worker / M IOCP free`; `~0 free with
  idle runspaces` is the fingerprint. **Guards:** `RunspaceManager.Tests` reads the
  floor back via `GetMinThreads`; `RunspaceWarmCoverage.Tests` statically asserts
  `SetMinThreads` precedes `CreateRunspacePool`; and `AsyncJob.LogStallHeartbeat`
  carries a latched runtime backstop — one `SetMinThreads` bump if a stall ever
  shows the starvation signature again (idle runspaces + ≤1 free worker thread), so
  a busy-runspace stall like a slow scan never trips it.

- **Startup provenance stamp.** Right after `DONUT starting up.`,
  `BuildProvenance::Stamp` logs one line with the git short SHA (+`dirty` flag) on
  clones — falling back to the launcher-written `version.txt` on prod installs —
  plus pwsh/CLR versions, machine name, and OS build. Field logs arrive detached
  from the code that produced them; the stamp makes every `Donut.log` attributable
  to an exact commit before any diagnosis starts.
- **Startup is STAGED — only the warm shells + the DC warm touch the pool at boot:**
  the finder/Lens warms and the startup-task heal are deferred until the DC warm
  completes (`HomePresenter.StartDeferredWarms`, with a 90 s fallback timer;
  `DonutApp.ps1` defers `ApplyStartupTask` 120 s). At 64dbec8 (known good) startup
  submitted exactly warm shells + DC warm; the stampede that accreted afterwards —
  one live-LDAP finder warm per forest, the Lens agent bring-up (20 s named mutex +
  ScheduledTasks COM + heartbeat wait), and the startup-task heal (another
  concurrent `Import-Module ScheduledTasks`; its own retry comment records the
  "Collection was modified" module-analysis race the boot storm causes) — all
  landed on the 8-runspace pool inside the same two seconds. That contends the
  **process-wide** module-analysis/loader locks and the WMI/Task Scheduler services
  against the warm barrier, and pool jobs freeze for minutes inside segments that
  are pure CPU (the `+0/+0/+0` GC watchdog signature). Never add pool work to the
  boot window; defer it behind the DC warm like these. Relatedly, **no live
  hashtable may cross the runspace boundary** — `Settings` *and* `Options` are
  deep-cloned on the UI thread at prep time (`RemoteServices.BuildWorkerArgs`), and
  `AppConfig.DeepClone` is cycle-guarded so a self-referencing tree cannot spin the
  dispatcher. `RunspaceWarmCoverage.Tests.ps1` guards the staging statically.
- **Thread safety:** `LogService` is thread-safe via **lock-free atomic appends** —
  every writer opens `Donut.log` in Append mode with ReadWrite sharing and emits one
  line per `Write` call, which the kernel serializes. It deliberately holds **no
  lock of any kind**: an earlier named-mutex design (2 s bounded wait + per-line
  `Add-Content`) collapsed under its own concurrency — with ~10 runspaces + the UI
  writing, every writer sat at the full 2 s timeout, each UI log line blocked the
  dispatcher ~2.2 s (the watchdog's own "dispatcher was blocked" warning write then
  caused the *next* block, an infinite warning storm), timed-out writers' fallback
  appends collided with the owner's and silently dropped lines, and warm jobs
  missed the 30 s startup barrier from logging cost alone. Logging must never be
  able to block the app it serves. Work is fed back to the UI through a
  thread-safe state/queue that a `DispatcherTimer` polls on the UI thread — **not** by
  returning results (which only surface when the runspace completes) — so the "live
  feed" updates in real time.
- **Every `AsyncJob` gets the real logger:** the 3-arg constructor is mandatory for
  production call sites (`AsyncJobLoggerCoverage.Tests.ps1` enforces it). The 2-arg
  form coalesces to `NullLogService`, which made every job failure — start errors,
  error-stream lines, completion exceptions — invisible in `Donut.log`; a wedged scan
  took days to triage because of that silence. The 2-arg form remains for tests only.
- **Every `AsyncJob` has a stall heartbeat:** `Poll()` logs a WARN once a job has run
  90 s without completing, then every 5 min, including the pool's free/max runspace
  count. That count is the discriminator this app's silent regressions always lacked:
  `0 free` means the job is queued behind busy or stuck runspaces (e.g. parked warm
  shells still holding theirs); free > 0 means the worker itself has not returned.
  Long scans legitimately cross the threshold — the heartbeat is evidence, not an
  error. Jobs put into `Running` without `Start()` (test doubles) never heartbeat.
- **Dispatcher watchdog semantics:** `DispatcherWatchdog` warns when its 250 ms tick
  gap exceeds the threshold, and appends the GC gen0/1/2 collection-count deltas
  across the gap (gen2 > 0 → a blocking GC suspended all threads; +0/+0/+0 → loader
  lock or synchronous UI-thread work). Ticks only fire while a message pump runs, so
  the first measurement after `Start()`/`Reset()` is discarded and `MainPresenter`
  calls `Reset()` right before entering `Application.Run` — otherwise pre-pump
  startup time gets charged to the first tick and reads as a fake multi-second block.
- **WizTree CSV is parsed streaming:** a full-drive export runs to hundreds of
  thousands of rows. `WizTreeCsv.ParseTopFoldersFromFile` reads it line-by-line on
  the pool thread; the earlier `-Raw` + `-split` + `ConvertFrom-Csv` pass
  materialized the file as a giant string, a line array, and a `PSObject` per row,
  and the resulting gen-2 GCs suspended the UI thread right as a disk scan finished.

## Remote execution (PsExec)

`PsExec` is the primary execution engine over native PowerShell Remoting: it runs over
SMB (port 445), avoids WinRM/TrustedHosts configuration, and natively supports
`SYSTEM` execution.

- **Encapsulation:** `ExecutionService` wraps the `PsExec` calls; `NetworkProbe`
  handles the pre-run checks (DNS, reverse-DNS, RPC), isolating network logic from
  execution.
- **Remote file handling:** UNC copy of the remote `outputLog` and `report` files,
  per-host temp logs, and report-XML consolidation before writing local logs; the
  `DellCommandUpdate` service is pre-stopped before running DCU.
- **DCU CLI syntax:** `dcu-cli.exe /<command> -option=value` (not `/key`); booleans as
  `-silent` or `-reboot=enable`. The remote work dir is `C:\temp\DONUT`.
- **Exit codes (see `DcuLog`):** `0` is the only unconditional success; `1`/`5` mean
  "completed, reboot required" (flagged, not an error); everything else is a real
  failure — including the small codes (`2` unknown, `3` not a Dell system, `4` not
  admin, `6` another DCU instance, `7`/`8` unsupported).
- **PsExec arguments:** `-s` (SYSTEM), `-h` (elevated), `-accepteula`, with
  `pwsh -NoProfile -NonInteractive -c` for clean remote execution.
- **Headless launch:** psexec is started through `ProcessStartInfo` with
  `CreateNoWindow` (a *hidden* console), not `Start-Process -NoNewWindow`. DONUT is a
  window-subsystem GUI with no console of its own, so `-NoNewWindow` makes the OS spawn
  a **visible** console per psexec; several at once sit in front of the WPF window and
  read as a frozen UI. A hidden console leaves psexec a *real* console — so its stdout
  is **not** redirected (redirecting it removed the console and caused remote
  `0xC0000142` init failures) — with no window. `ExecutionService.StartPsExecHidden`
  is the shared launcher.
- **Scan launch/wait breadcrumbs (under investigation).** A Scan that "runs forever"
  is bounded (`WaitForRemoteProcess` kills + throws at 30 min) and SMB-gated, so the
  wedge is inside the silent launch→wait segment. `RunScanPhase` brackets the launch
  with `Scan: psexec launch start` / `… done in N ms (exit C)`; `WaitForRemoteProcess`
  emits a 30 s `still waiting after N s (remote process running)` heartbeat; and the
  scan tick logs `DCU /scan tail: +N log chars in last ~30 s (… SMB reachable=B)`.
  Read them together: a `start` with no heartbeats ⇒ never launched; heartbeats with
  `tail +0 chars` while `reachable=True` ⇒ `dcu-cli` is running but writing nothing
  (the wedge to chase); `tail +N` ⇒ it's progressing, just slow.

## De-elevating the user Lens

DONUT runs **elevated as an admin account** (required for the psexec/CIM remote work),
but the user Lens data is only readable by the operator's **regular account**: the
person→device mapping and hardware inventory come from **SCCM** (its AdminService is
RBAC-scoped to the regular account, not the admin one), and BitLocker recovery keys sit
in **AD** under the computer object. Elevating does not grant the regular account's
rights — a separate identity means a separate process.

**A persistent de-elevated agent:**

- A single **`LensAgent.ps1`** runs de-elevated as the **interactive user** for the
  app's whole lifetime, started via a **scheduled task** (`LogonType Interactive` = the
  logged-on token, *no password*; `RunLevel Limited` = medium integrity; action wrapped
  in `conhost.exe --headless` so no console window ever flashes). `Shell.Application`
  was tried and rejected — it only de-elevates within the *same* user.
  `FinderPresenter.WarmLens` starts it on the pool at app startup (fire-and-forget, in
  parallel with the pool/AD warm), so as its own process it pre-warms its AD/SCCM
  libraries while DONUT is still booting — and even the **first** pick skips the
  per-lookup task registration + `pwsh` cold start (~2-4 s) the previous one-shot-task
  design paid every time.
- `PersonLensService` is the agent's **supervisor + client**. `EnsureAgent`
  (mutex-guarded so concurrent pool runspaces can't double-start) treats a
  `heartbeat.txt` older than 15 s as a dead agent and re-registers the task;
  `RunLookupJson` then drives one lookup over the exchange. The agent beats from a
  **background thread** (not the serve loop), so a lookup in flight — which blocks the
  serve loop for tens of seconds — never lets the beat go stale and get the busy agent
  torn down mid-lookup. It self-exits when DONUT's process dies (a `-ParentPid`
  watchdog), when a `stop.flag` appears, or when the exchange dir is purged.
- The agent reads AD forest-wide via the **Global Catalog** (`GC://...`, then binds
  each object's home domain) and SCCM via the **AdminService REST** endpoint
  (`-UseDefaultCredentials`, no ConfigMgr module/PSDrive). The parse
  (`PersonLens.FromJson`) is pure/tested; the agent/task I/O is the overridable
  `RunLookupJson` seam. The `%5C` (backslash) gotcha in the SCCM query is avoided by
  filtering on the forest-unique SAM (`endswith`) and exact-matching client-side.
- The **AD finder search runs in-process on the pool, not through this agent**:
  `FinderPresenter` fans out one `AdSearchWorker` job per forest, each calling
  `ActiveDirectoryService.Search` as the elevated admin - AD reads don't need
  de-elevation. (It was briefly routed through the agent to reuse warm binds, but that
  dragged the agent's cold start - CIM + scheduled-task module load, which takes the
  process-wide CLR loader lock, plus a ~2-4 s `pwsh` spawn - onto the per-keystroke path
  and froze the UI, so it went back to the warmed pool.) A lookup is offloaded to a
  `ThreadJob` so a slow one never blocks the serve loop.

**The exchange protocol** (fixed `%ProgramData%\DONUT\lens-agent` dir): the parent drops
`request-<id>.bin`; the agent answers `partial-<id>-1.bin` (directory facts),
`partial-<id>-2.bin` (name-only device rows) and `result-<id>.bin`. Each side deletes
what it consumed; the agent sweeps anything older than 10 minutes.

**Securing the exchange (the bundle holds BitLocker recovery keys):**

- The exchange folder's inherited ACL is **stripped** (ProgramData grants all local
  users read) down to SYSTEM / Administrators / the interactive user.
- Every payload is **AES-256-CBC encrypted** with a **per-session key** minted when the
  agent starts (`key.bin`, 32-byte key + 16-byte IV;
  `PersonLensService.ProtectText`/`UnprotectText`/`WriteEncrypted` are the unit-tested
  twins of the agent's inline crypto). Nothing touches disk in the clear. The ACL-locked
  dir is the real boundary; the key is defense-in-depth.
- On window close the parent drops `stop.flag`, **stops + unregisters** the task, and
  deletes every `lens-*` dir. The per-person UI cache is **memory-only**
  (`FinderPresenter.LensCache`, 15-min TTL), so it dies with the process.

**Keeping it fast:** the agent is already warm (no task/`pwsh`/library cold start per
pick); one SCCM call total (the affinity query, person → WSIDs) with everything
per-device read from the computer's AD object; the affinity query runs on a thread job
in parallel with the AD user read; and the agent streams **sequential partial bundles**
(directory facts, then name-only device rows, then the filled detail) so the UI paints
progressively. The AdminService `/wmi` route's OData translator rejects richer filters
(`or`, backslashes) with **404**, so per-device SCCM detail queries were dropped rather
than fought.

## UI & threading

WPF UI updates must happen on the UI thread, and past freezes came from background
threads touching the UI directly.

- **Polling, not marshalling:** state changes (`ScanStarted`, `ScanCompleted`, log
  lines) update a thread-safe state object/queue; a single `DispatcherTimer` drains it
  on the UI thread in batches. DONUT does **not** use `Dispatcher.Invoke` /
  `BeginInvoke` for this — flooding the dispatcher with per-event invocations was a
  freeze source.
- **ApplyUpdates two-phase flow:** temporary scan config → run scan → copy report XML →
  gather remote driver/app data via PsExec → brand-based matching → per-host
  confirmation popup (skip apply if not confirmed) → skip apply when no updates → copy
  the updates list to the clipboard.
- **Manual reboot detection:** parse log lines for reboot-required vs auto-reboot;
  surface a completion popup listing machines needing manual reboot. Pre-seed the
  manual-reboot list when config disables automatic reboot (`reboot`/`forceRestart`).
- **Multi-device safety prompt:** if ApplyUpdates is enabled and multiple hosts are
  queued, show a single confirmation listing all targets before enqueueing runspaces.

## Configuration & persistence

- **JSON config:** `config.json` (migrated from the old `config.txt`); `wsid.txt` and
  `config.json` live under `%LOCALAPPDATA%\DONUT\` so they persist across updates and
  reinstalls. `ConfigManager` reads/writes both, prioritizing the `%LOCALAPPDATA%`
  copy.
- **Structure:** `AppConfig` merges user settings with `[AppConfig]::Defaults` so all
  expected keys exist. The full key list — commands, throttle, tray/hotkey/autostart,
  machine-name patterns, and more — is documented in the
  [config.json reference](../../configuration/config-reference.md).
- **`AppConfig.BuildDcuArgs()`** generates DCU CLI format: `-option=value` syntax,
  boolean `true` → `-silent` / `-reboot=enable`, `false` → omitted (or `=disable` if
  explicit), empty strings omitted, values with spaces quoted. See the
  [DCU command reference](../../configuration/dcu-commands.md).
- **Real-time settings:** the settings overlay has no Save button — every control
  persists on change (text fields on focus loss), and side-effectful keys re-apply
  immediately (hotkey re-registration, startup-task reconcile).

## PowerShell constraints to retain

- **Absolute script paths in runspaces:** child runspaces must receive absolute script
  paths because `AddScript` rejects relative paths in the packaged build.
- **Window chrome for resize:** XAML `WindowChrome` with `AllowsTransparency="False"`,
  `WindowStyle="None"`, `ResizeMode="CanResize"`, and
  `WindowChrome.ResizeBorderThickness="6"` keeps edge/corner resize without any P/Invoke.
- **`InstallWorker.ps1` stays a standalone script** (not a class) in `src/Scripts/` so
  `SelfUpdateService` can copy it to `%LOCALAPPDATA%\DONUT` and run it independently
  for updates/rollbacks; the copy is hash-gated (SHA-256) to avoid needless writes, and
  Device Flow tokens are DPAPI-protected (CurrentUser).
- **Every dev-path C# helper guards its own type:** `Start-Donut.ps1` compiles the
  `src/Launcher/*.cs` helpers with `Add-Type` when their types are not already
  resident (production compiles them into `Donut.Launcher`, which also *hosts* this
  script). Each file must sit behind its **own** `-as [type]` guard and compile
  alone: hiding several helpers behind one guard type crashed startup with
  "Unable to find type [WindowChromeHelper]" — a session with the MVVM types
  resident (an installed launcher older than a newer helper, or a console that had
  run an older tree) skipped the whole block, and the class-graph parse died on the
  first missing type. Per-file guards compile exactly what is missing and never
  recompile a resident type (a duplicate would make the name ambiguous across
  assemblies). `StartupDevPath.Tests.ps1` enforces the rule.
