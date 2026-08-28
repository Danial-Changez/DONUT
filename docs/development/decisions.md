---
title: Design decisions & postmortems
description: The engineering history behind the rules - dated regressions, measurements, and rejected alternatives, one section per topic.
---

The reference pages state the current rules. This appendix keeps the history that
produced them: what happened, what changed, and the rule it left behind.

## Runspaces and workers

### Worker isolation (the DC-warm/scan saga)

Running the worker class graph in-process on pool runspaces deadlocked: two or more
runspaces cold-loading the `using module` graph concurrently hang on PowerShell's
module-load lock (commit `64dbec8` only worked because ThreadPool starvation
accidentally serialized execution). Workers moved to isolated child `pwsh` processes;
the pool stays for throttling only. Validated at 8-way concurrency with zero deadlock.

### The forked-launcher wedge

`WorkerProcess` once spawned `[Environment]::ProcessPath` as the child executable. In a
launcher-hosted run that is `Donut.Launcher.exe`, so each job forked a second DONUT
that bowed out via the single-instance guard: exit 0, no result file, read as a
silent success, wedging the caller. The child is now `WorkerProcess.FindPwsh()`, and
`Interpret` fails an exit-0 run that produced no result file.

### Warm compile serialization (fixed 2026-07-23)

Compiling the class graph in 4+ runspaces at once deadlocks on the module-load lock
(2-3 concurrent are fine; reproduced end-to-end). Field logs showed scans reach
"Worker up" then hang, queued behind the wedged warm compiles. `WarmPool` now warms
one runspace at a time; the first compile (~0.5 s) primes the module-analysis cache,
the rest reuse it (~30 ms). Priming does not make concurrency safe, since the
deadlock is on the lock, not a cache miss, so serialization is mandatory, not an
optimization.

### ThreadPool floor (fixed 2026-07-23)

A `RunspacePool` dispatches pipelines on .NET ThreadPool threads, whose floor defaults
to `ProcessorCount`. Eight warm shells at startup saturated it, and further dispatch
waited on the ThreadPool's ~1-thread/second injection: runspaces reported idle while
jobs sat `Running` for minutes (a live-app stack dump via
`tools/Get-DonutRunspaceStacks.ps1` pinned it). `RunspaceManager.Initialize` now
raises the floor before creating any pool. Fingerprint if it recurs: stall heartbeats
logging `~0 free` ThreadPool workers alongside idle runspaces.

### The superset warm and the loads-only warm

Two warm variants shipped and regressed:

- A `Warm-Runspace.ps1` (2026-07-20, since removed) loaded the full AD + Lens graph
  and binary CIM/ScheduledTasks modules per runspace; 8 concurrent copies contended
  the process-wide loader locks, shells stopped fitting the 30 s barrier
  (`Pre-warmed 0 of 8`), and every feature queued behind a starved pool.
- A loads-only warm (imports without first-use exercises) shipped once, and the first
  live resolve-IP and disk-scan jobs (whose opening act is a first DNS/socket
  connect) stopped completing.

Hence the current rules: the barrier carries exactly one real worker pass per
runspace, the first-use exercises are load-bearing, and nothing unproven goes under
the barrier. Wedge risk is carried by the barrier's park-and-reap design: a late
shell is never `Dispose()`d, `Stop()`ped, or async-stopped; each of those three
shipped its own regression (the first two hang on a wedged pipeline; the async stop
destroyed warms that were merely slow, e.g. first-run AV/AMSI scanning).

### Startup staging stampede

Before staging, one live-LDAP finder warm per forest, the Lens agent bring-up, and
the startup-task heal all landed inside the same two seconds as the warm barrier,
contending the loader locks and the WMI/Task Scheduler services. Pool jobs froze for
minutes inside pure-CPU segments (the `+0/+0/+0` GC watchdog signature). Rule: never
add pool work to the boot window; defer it behind the DC warm.

### The LogService named mutex

`LogService` once serialized writers through a named mutex, which collapsed under its
own concurrency: 2 s waits per writer, dispatcher blocks, a warning storm, dropped
lines, warms missing the 30 s barrier from logging cost alone. It now uses lock-free
atomic appends (one line per `Write`, kernel-serialized). Rule: logging must never be
able to block the app it serves.

### The fast resolve lane

The classic path paid a full worker child (pwsh cold start + class-graph compile,
~2.5-5 s) for one DNS query and one TCP probe, and held a pool runspace for the
child's life, so resolves queued for minutes behind scans. The fast lane spawns a
slim class-free `ResolveWorker.ps1` directly (~1-2 s, no pool slot), verdict via
result file (redirected pipes are the proven wedge surface). A pinned resolver
process (`-Serve` loop) was designed and deferred: it would save ~1-1.5 s per resolve
but adds supervision complexity. Build it only if field logs show resolve wall time
still gating something a user watches.

### The 150 ms bar

Fanning work across the small interactive pool is only worth it when a single leg is
slower than the machinery around it (~150 ms, the Lens agent's serve-loop pass). Two
decisions came from applying it:

- The Lens owner lookup is one batched request, not one per machine: N requests
  cost N files, AES round trips, and polls. The agent now serves the batch on a
  thread job, but the batching still pays for itself.
- An AD-search debounce/poll raise (100→250 ms / 60→150 ms) was reverted: the
  debounce charged every search a flat +150 ms to avoid a cost that was argued rather
  than measured, and the poll timer never ticks while idle, so a fast tick costs
  nothing. Raise it again only on log evidence.

### The dropdown render postmortem

The four-span AD-search breadcrumb showed all four forests finishing within 27 ms of
each other while totals spread across 465 ms, all in `notice`, because `PollSearch`
re-rendered the dropdown per landed leg on the UI thread. Worse, the render cost was
linear (~3 ms/row): `SearchResults.Clear()` + per-row `Add` on a bound
`ObservableCollection` raises `CollectionChanged` and invalidates ListBox layout per
row, so a 55-row render was 55 layout passes. Fixes: render once per poll tick, and
hand the list over in one `Set` so the ListBox does a single reset (~55-70 ms flat,
under the bar). Rules: never populate a bound collection item by item on a path a
user is waiting on, and no UI-thread work inside a poll loop, since it gets charged
to whichever job is read next.

Cancelling remaining forests once one answers stays off the table: forests hold
disjoint populations and the dropdown applies no cap or relevance ranking, so an
early stop would drop real people based on which forest won the race.

### The WizTree CSV parse

The earlier `-Raw` + `-split` + `ConvertFrom-Csv` pass materialized a giant string, a
line array, and a `PSObject` per row; the resulting gen-2 GCs suspended the UI thread
right as disk scans finished. The parse now streams line by line, the target trims
the export to the N largest rows before it crosses SMB, and the ~40 MB full export
never leaves the machine.

## AD queries

### ANR: measured and rejected

`(anr=dan)` returned 15 hits against the four-clause filter's 10, and the identity
pass showed every extra was a surname match. Nothing came from ANR's other
attributes. So the filter gained one indexed `(sn=$p*)` clause and ANR stayed out:
its breadth (office names, `proxyAddresses`, `legacyExchangeDN`) could crowd real
people out of the per-forest cap, and `userPrincipalName` is not in the ANR set
anyway. Surname-only hits rank last in `AdSearchRank`, inferred rather than read:
`sn` is deliberately not in `PropertiesToLoad`, so a row matching no visible field
can only have arrived via the `sn` clause. Re-run `tools\Measure-AdSearch.ps1` if the
filter changes.

### Referral chasing

`ReferralChasing = None` was measured against the default `External`: hit counts
identical everywhere, ~6 ms saved, far under the 150 ms bar, so the default stays.
The test is the hit count, not the clock: fewer hits would mean referrals are
load-bearing for a child domain.

### The misspelt forest

`AdSearchWorker.ps1` constructs its service with a null logger, and
`LogService.Coalesce` turned the per-forest catch's warning into a no-op, so a
configured forest whose DNS name carried a stale spelling quietly returned nothing
for a quarter of every search. Failures now ride the warning stream to
`FinderPresenter.ReportForestFailure` (logged, search marked `FAILED`, one toast per
forest per session). Note: fixing a default does not fix an install. User settings
merge over defaults, so a wrong value saved in `config.json` keeps winning.

### Most of a search is not the query

An earlier version of the AD page credited residual per-forest time to forest
latency. Measurement said otherwise: LDAP alone ran ~90-205 ms per forest while
`Donut.log` recorded 337-601 ms for the same search. The gap was the dropdown
re-rendering per forest (see the render postmortem above), not the directory. The
in-app `search` span is uniform across forests; "the slow forest" was a totals
artifact. Do not re-quote pre-fix per-forest figures: they were taken while one
forest was misconfigured and with a 150 ms poll adding measurement error.

## User Lens

### Rejected agent designs

- `Shell.Application` de-elevation: only de-elevates within the same user, so
  rejected for the agent launch (scheduled task with `LogonType Interactive` instead).
- One-shot task per lookup: paid task registration + `pwsh` cold start (~2-4 s) every
  time. Replaced by the persistent agent warmed at startup.
- Routing the AD finder search through the agent: dragged the agent's cold start onto
  the per-keystroke path and froze the UI. Finder search stays in-process on the pool
  (AD reads don't need de-elevation).

### AdminService filter shapes

The `/wmi` route's OData translator rejects richer string filters (`or`,
backslashes) with 404, and a site that will not serve a filter answers either 404
**or** 200-empty. Treating only the 404 as rejection is what made model and service
tag silently absent from device cards. Rules: the affinity query filters on the
forest-unique SAM with `endswith` (no `DOMAIN\sam` backslash in a URL), the hardware
pass filters `ResourceID eq N` and falls back once to the keyed segment `Class(N)`,
and both empty shapes fall through. Also: the URL builder writes `${class}?` with
braces: `"$class?"` parses `class?` as the variable name and the class vanishes from
the path, silently.

### The software list shows packages instead of guessing at them

The user Deployments view keeps install-intent applications and **every** package
deployment. Package program names vary per site ("Install", silent variants,
maintenance scripts), so no generic filter can sort software from noise. The row
carries the program name instead and the operator tells them apart, exactly as the
console's Program column does. Site-specific collection naming conventions stay out
of the code: the optional `lensSoftwareCollectionFilter` config regex narrows by
collection name at render time, and its blank default shows everything. The chain
(`SMS_R_User` endswith → `SMS_FullCollectionMembership` `ResourceID eq N` → one
`$select`-trimmed `SMS_DeploymentSummary` fetch with `DesiredConfigType` served) is
field-confirmed against the site this ships to.

### Naming owners (why SCCM comes first)

Owner chips once shipped showing SAMs. `SMS_R_User.FullUserName` names the person
first because the site aggregates users from every forest, while `Find-Gc` reads only
the agent's own forest's GC and can never name a sibling-forest user. The GC stays as
fallback for its one forest; resolved names memoize per agent session. A cached
one-token owner (the pre-SCCM SAM shape) still displays but is re-asked once per
session, so old caches heal instead of pinning the SAM forever.

### Software push through collections (deferred 2026-08-26)

The ask: push approved software to a person from their Lens. At the site this
ships to, the apps are application deployments on **user** collections, marked
Available, so a push is a direct membership rule on the app's collection
(`SMS_Collection(id).AddMembershipRule`), a `RequestRefresh`, and a user-policy
nudge to the person's devices. `tools/Probe-SccmNotify.ps1` walks that chain over
the AdminService and, with `-Wmi`, over the SMS Provider.

Field-confirmed: the `/wmi` route calls the method (the array form
`AddMembershipRules` is not served), the catalog is the Lens software fetch
unfiltered, and the operator reaches SCCM through a group holding Remote Tools
Operator and a reports role, which is read-only on collections. The provider
refuses the rule with "insufficient rights" on either route. The site's own
self-service push runs as a service account holding a custom
collection-membership role, and grants operators access at its own level, not
through SCCM.

Deferred until operators hold that role. The design when it lands: `Push…` in the
Lens header, the shared dialog with a choice row over the catalog (the
`lensSoftwareCollectionFilter` regex scopes what is pushable), one request kind
on the Lens lane, and the software list re-fetched as the result. No service
account inside DONUT: the Lens runs as the operator on purpose, and a push under
a shared identity would lose who did it.

## Elevation and autostart

### The deleted SYSTEM autostart lane

Autostart once registered a SYSTEM task that relaunched DONUT into the console
session through psexec (a task cannot start an elevated process as a non-admin's
separate admin account). It worked and it was broken: as SYSTEM the instance
authenticates on the network as the **machine account**, which has no rights on fleet
targets: a working UI that failed every remote job. Deleting the lane fixed a bug
rather than only simplifying code. Do not reintroduce it.
`tools\Diagnose-StartupTask.ps1` flags a SYSTEM principal or psexec action as a task
left by an older build. Related rules that came from the same work: the trigger binds
to the console user (a task triggered by an account that never logs on stays `Ready`
forever), and the run-as account is never derived from `$env:` (under SYSTEM that
names a nonexistent account).

### psexec `-i` defaults to the caller's session

The psexec docs say an unspecified session means the console session;
field-verified otherwise (2026-07-27): from a SYSTEM task, `psexec -s -i -d` landed
DONUT in session 0. Always pass the session id explicitly. With `-d`, psexec's exit
code is the launched PID, so a "failed" task result like `10176` is actually success.

## Architecture seams

### Presenters keep their name

The `*Presenter` classes act as coordinators/UI-services, not MVP passive-view
presenters, since bindings are the default render path. A rename to
`*Coordinator`/`*Service` would be cosmetic churn across the UI layer, so the name is
retained by choice (`ToastService` already carries the accurate suffix). Each keeps
only imperative work MVVM sanctions: dialog lifecycles, live log appends, popup
positioning, spotlight geometry, the WinForms `NotifyIcon`.

### The coordinator seam

Clusters carved off `HomePresenter` (`FinderPresenter`, `InventoryPresenter`,
`ResolutionCoordinator`) follow one seam: a duck-typed `[object] $Home` back-ref (a
typed field would create a `using module` import cycle); when a cluster couples to
shared coordination state, only the execution moves out and the gate stays with its
owner (reachability gate, run/gather queue); shared objects (`HostResolver`) are
passed by reference, not handed over. The remainder (pump + run/apply + shell) is
the irreducible core, left intact rather than fragmented into further indirection.

## UI decisions

The current rules live in [UI reference](./ui-reference.md); this is why they are
what they are.

### The "Add typed text as a machine" row

The finder dropdown once offered the typed text as a first-row add. A pattern prefix
like `cap-` pre-selected it, so Enter created a junk `cap-` card while the actual
CAP- machines sat one row below. The row is gone: Enter acts on real rows only,
pre-selecting the top-ranked computer (else top user); the one non-row Enter is a
pasted multi-token list.

### The removed status filter tabs

The machine pane's All/Online/Offline/Attention filter tabs forced a second header
row that broke the two panes' header alignment and earned little at small fleet
sizes. The fixed status-grouped sort (attention first) stayed; only the interactive
filter went.

### Checkbox cascade goes downward only

The folder tree shows only the largest folders, so a parent's visible children are
not its whole contents. The old roll-up (all visible children checked ⇒ parent
checked) escalated one child's clear into the parent's entire on-disk contents.
Selection now cascades downward only, and unchecking a child releases any checked
ancestor.

### Tooltips on untrimmed text stay unconditional

`IsTextTrimmed` is UWP/WinUI-only; WPF's `TextBlock` cannot report whether it
trimmed, and a `Trigger` on the property does not fail at parse. It breaks the whole
enclosing template at load. Gating would need an attached property in `Donut.Mvvm`.
Until that exists, a tooltip repeating fully-visible text is accepted noise.

### The Lens device card

The card's job is telling a person's three similar laptops apart. A labelled
two-column `MODEL`/`TAG` grid was built and rejected (repeated labels per card, a
header block that cannot own columns across bordered cards, and an implied sort
interaction the fixed ordering does not offer). The OS moved to the row tooltip: a
person's machines nearly always share one OS, so the field spent the most prominent
sub-line saying nothing.

### The elevation badge

A toast alone was not enough for de-elevation: a transient notification answers
"what just happened", not "what am I in right now". The standing amber `LIMITED`
badge is driven by `ElevationContext::IsElevated()`, never by `runAsAdmin`. The
setting records what was wanted; the badge reports what the process actually got.

### Surfacing from the tray

Restoring from the tray once ran `Window.Show()` before the deferred sign-in/update
prompt, putting the main window and the login modal on screen together, so the app
looked like it had opened twice. The prompt now runs before `Show()`, the order a
cold start already used.

### The inverted QR

The BitLocker QR renders violet-on-transparent by choice, blending into the dark
card. Field-gated on the hardware scanner: older 2D imagers often can't decode
inverse QR. If it fails the scan test, revert to dark-on-light (recipe kept at the
`QrModule*` keys) rather than tweaking colours.

### The 2026-08-23 UI audit

The app and the docs were read against the Vercel Web Interface Guidelines and the
anti-template design checklists. The rules that came out of it are on the
[UI reference](./ui-reference.md). This is what was wrong.

`FontSans` named Montserrat, a font the app never shipped, so it rendered in Segoe
UI while the docs rendered in Geist. WPF's dotted focus adorner is invisible on
near-black, and a `ToolTip` reaches UIA as help text, so the icon-only buttons had
no focus ring and no accessible name. Text came in thirteen sizes across 81 inline
declarations, none of them a role. A toast carried its one accent four ways, one of
them a bitmap glow. No storyboard read the OS animation setting. A switch and its
label were siblings, so the label was a dead zone. The window controls wore macOS
hover colours. Uptime sat under the DISK label. The password rule was a red border
and a toast.

On the site, the diagram lightbox opened on click only and never took focus, the
hero was the stock gradient text over a mesh, and nothing read
`prefers-reduced-motion`.

The faux window that stood in on the splash is gone: `tools\Show-View.ps1 -Main`
composes the real main window with sample data and renders it off-screen, so the
splash shows an actual screenshot and `assets/Screenshots` is current again.

### Montserrat, shipped this time

The audit swapped the never-shipped Montserrat for the docs site's Geist. Rendered
side by side (`tools\Show-View.ps1 -Main -Font 'Segoe UI'` against the embedded
face), the choice came down to Montserrat or Segoe UI, and Montserrat won on look.
So the sans is Montserrat for real now: the four static weights are embedded under
`src/UI/Styles/Fonts` (OFL) and the launcher's pre-WPF dialog loads the same files.
Geist Mono stays for the mono tier, and the site keeps Geist for its own text.

Two things came with it. Montserrat sits taller than Segoe UI and the type ladder
rounded every size up, so the gaps inside cards read cramped until they grew with
the face; a stat tile now keeps equal ink gaps, measured on a render rather than
eyeballed: 16 between its three lines and 18 from the top and bottom edges. The
copy pill on a value hugs the value instead of spanning the row. And the
casing rules were re-applied to what the audit missed (`Sign In`, `What's New`,
`Press Keys…`, `BIOS`, `Reboot Required`), with the reference now naming status
chips and toast titles as Title Case and toast bodies as sentence case.

## Releasing

The current rules live in [Releasing](./releasing.md); this is why the version
looks the way it does.

### Why the third field counts builds, not patches

Semantic versioning has no place to put a build: a prerelease is a suffix
(`2.5.0-beta.3`) and build metadata (`+776`) is defined as ignored when ordering.
Neither survives the round trip. The number DONUT compares is not the git tag but
the MSI's ProductVersion, read back as `DisplayVersion` from the uninstall key, and
that field is three numeric fields with no suffix, and `[version]` cannot parse one
either. Something numeric and monotonic has to exist per build, and the third field
is the only slot for it.

`Major.Minor.Patch.Build` fails harder than it looks. Windows Installer parses the
fourth field and then ignores it, so `2.4.0.776` and `2.4.0.777` are the same
version to it. The package auto-generates a ProductCode per build and `MajorUpgrade`
only removes products strictly older than the incoming one, so an equal version
removes nothing: two builds in a row leave two live entries in Add/Remove Programs
with the files of whichever installed last.

### Rejected: semver-shaped stable releases

Stable could read `X.Y.0` with betas at `X.Y.<build>` and each stable bumping the
minor (`2.5.0` stable, `2.5.78x` betas, `2.6.0` stable). Ordering works and the
workflow already supports it, since a hand-pushed tag is the stable path. It was rejected
because a stable release then has a different version from the beta it came from,
which makes it a rebuild: what ships is no longer the artifact testers ran. Keeping
promotion a flag flip is worth more than a patch digit, which in practice would only
ever have been `0`.
