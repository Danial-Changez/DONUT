---
title: Implementation notes
description: How the design handles remote execution, threading, de-elevation, configuration, and PowerShell's constraints.
---

How the design handles the constraints of remote execution, threading, and packaging.

## Parallel execution (runspaces)

The original tool used PowerShell runspaces for parallel execution; DONUT keeps that
model.

- **Classes in runspaces:** PowerShell classes are not automatically available in new
  runspaces, so the required class modules (`Models`, `Services`) are explicitly
  loaded into each runspace before execution.
- **Pool warm = graph load + one real worker pass, LOADS ONLY:** at startup
  `ResolutionCoordinator.WarmPool` runs `Warm-Runspace.ps1` once per pool runspace
  (concurrently, behind a barrier). It `using module`-loads the superset of every pool
  worker's class graph, imports the binary CIM/ScheduledTasks modules, and then
  **executes `RemoteWorker.ps1` once** in `Mode='WarmRunspace'` (real pipeline
  construction + `WarmRuntimeAssemblies` + `WarmScanLaunchPath`). Pre-loading the
  graph alone is not enough: when a runspace's first `RemoteWorker.ps1` execution
  happened on a live job, that job wedged silently — the startup DC discovery never
  logged a line, `HostResolver` never got an active DC, and every resolve/inventory
  quietly no-oped (the machine-list regression). The same first-execution rule
  applies *per code path*: a live DCU scan once wedged between "Starting preliminary
  scan" and the psexec launch on the first-ever `InvokePsExec` in the process, so the
  warm also pre-executes the CPU half of the scan launch path (dcu-cli arg build,
  remote-script build + encode). **No connection of any kind may ever open inside
  the warm — remote or local.** A loopback port-445 probe added "to bind the socket
  stack" wedged *inside* the native connect (security stacks hook socket connects;
  the hook blocks below any PowerShell-level timeout), every warm job hung, and the
  app never showed a window. Removing it was not enough: the warm's *local* WMI
  query, scheduled-task lookup, localhost DNS resolve, and loopback DCOM session are
  RPC/native connects too, and the same hooks wedged 7–8 of 8 warm jobs
  *unstoppably* (the pool still `0/8 free` 90 s after the background stops were
  requested). The warm now performs module/assembly loads and script compilation
  only; first-use *connection* costs land on live pool jobs, whose gates are bounded
  and off the startup barrier. `WarmPool`'s barrier (default 30 s,
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
  (pool free: 0/…)`, and Resolve-job stall heartbeats with `0/… free`.
  `RunspaceWarmCoverage.Tests.ps1` guards the static rules (no-connect across
  `WarmScanLaunchPath`, `WarmRuntimeAssemblies`, and `Warm-Runspace.ps1`; the
  self-heal; park-and-reap with no Stop of any kind);
  `tests/Integration/WarmPoolBarrier.Tests.ps1` proves the lapse path returns
  promptly, heals capacity, dispatches work while shells are parked, and reaps
  late warms back to the configured throttle; and
  `tests/Integration/StartupResolveSmoke.Tests.ps1` runs the real warm + resolve
  scripts on a real pool and asserts they always terminate (the "`Started Resolve
  job.` then silence" regression family).
- **Thread safety:** `LogService` is thread-safe. Work is fed back to the UI through a
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
