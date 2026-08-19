---
title: Elevation and autostart
description: How DONUT decides whether it is elevated, when it relaunches itself, what the first elevated launch sets up, and the one data root.
---

Every remote operation authenticates as the DONUT process itself. That one fact
drives the whole elevation model: de-elevated, DONUT is the console user, who has no
administrative rights on fleet targets.

![Configuration and persistence class diagram](/diagrams/class_config.svg)

*Source: [`class_config.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_config.puml)*

The round trip a gated click takes when DONUT is de-elevated:

![Elevation round trip sequence diagram](/diagrams/elevation_sequence_diagram.svg)

*Source: [`elevation_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/elevation_sequence_diagram.puml)*

## The model

- **`asInvoker`, not `requireAdministrator`.** DONUT opens as whatever account
  started it and relaunches itself when it needs more.
- **`ElevationContext` is the only place that reads the token.** `IsElevated` asks
  whether the process carries the Administrators group; `IsSystem` is the narrower
  service-token question. `Classify` is the pure rule the UI gates on and takes the
  elevation state as a parameter, so it unit-tests on any platform.
- **`runAsAdmin` defaults to `true`** — the only boolean that falls back to `true`
  on a corrupt value, because guessing wrong yields an app where nothing remote
  works.
- **One prompt per session, never per action.** Elevating relaunches the whole UI;
  once it succeeds every gate is open for the life of the process.

## The first elevated launch

The launcher finishes machine setup on the first elevated run, in two steps:

1. **`Program.ExtractEmbeddedApp`** self-extracts the embedded app tree beside the
   exe (SHA-256 verified per file). The tree is what an elevated DONUT executes, so
   it is deliberately **not** writable de-elevated — local-user write access there
   would be a privilege escalation. A de-elevated launch against a stale tree gets
   start-as-admin-once guidance.
2. **`Bootstrap.Run`** (`src/Launcher/Bootstrap.cs`) installs missing operator
   prerequisites. Idempotent: each later launch re-checks cheaply and skips, and a
   failure warns and retries at the next elevated launch, so an offline install
   still opens the app. It raises that warning through a `warn` callback rather
   than a dialog of its own, so it stays compilable without a UI assembly graph;
   `Program` supplies one that opens `ErrorDialog`.

Both funnel into the same window. `ErrorDialog` (`src/Launcher/ErrorDialog.cs`) is
a hand-themed WinForms form, because these paths run before WPF exists and two of
them run *because* it failed to load. It leads with a one-line reason, follows with
what to do, and keeps the exception behind a Details toggle. The three PowerShell
call sites still use `MessageBox`: the dev path runs under plain `pwsh` with no
launcher assembly, so a hard type reference there would not parse.

| Prerequisite | Source | Lands at |
|---|---|---|
| PsExec | Sysinternals `PSTools.zip` | `System32`, so `PATH` resolves it |
| PowerShell 7 | Latest GitHub release MSI, silent | Its own installer location |
| WizTree | The vendor's portable zip | `<app tree>\src\Tools\wiztree64.exe` |

The RSAT ActiveDirectory module used to sit in that table, fetched through
`dism /Add-Capability`. It bought three cmdlets — `Unlock-ADAccount`,
`Set-ADAccountPassword`, `Set-ADUser` — and cost a Feature-on-Demand download that
ran for minutes on a first run and never returned at all where Windows Update was
blocked by policy. All three have `System.DirectoryServices` equivalents, which is
what `ActiveDirectoryService` writes through now, so nothing installs it.

Every download is Authenticode-verified against its expected publisher before it
is used, because each one later runs elevated. Neither PsExec nor WizTree may be
redistributed, which is why they are fetched rather than shipped in the MSI.
WizTree is skipped when the file already exists, so an operator-supplied copy
carrying their supporter code wins over a fresh unregistered download. The
extraction pass spares that path when pruning, since it is not an embedded
resource.

## Relaunching

`MainPresenter.RestartElevated` and `EnsureElevated` share one `SpawnElevated`, and
the order is load-bearing:

1. Persist anything that must survive the swap.
2. `Start-Process -Verb RunAs` — the prompt comes **before** any teardown, so a
   declined UAC leaves a fully working app.
3. Only on success set `ExitRequested` and close the window.

A declined prompt raises `Win32Exception` 1223 (`ERROR_CANCELLED`): the toggle path
reverts the setting; a gated action discards its note and undoes a remembered
choice. Turning `runAsAdmin` off applies at the next launch (Windows has no
un-elevate API), and the UI says so.

The single-instance mutex is `Local\`-scoped — per-session, not per-token — so an
elevated relaunch would collide with its de-elevated parent. Both hosts wait the
predecessor out first: `--await-pid` in the launcher, `-AwaitPid` in
`Start-Donut.ps1`.

## Gated actions

Scan, apply, inventory, storage scan, clear selected, and the Start with Windows
toggle all need administrator rights. Clicking one while de-elevated records what
was clicked, elevates, and re-runs it.

- **`PendingIntent` is untrusted input** — written de-elevated, read elevated. It
  carries only an action kind and host names; `FromJson` matches enum *names*, not
  `[enum]::TryParse` (which accepts a numeric string).
- **`DeleteFolders` is never resumed.** Its folder list lives in the window's
  selection, and it is the one destructive action — the user re-picks after
  elevating.
- **A note fires at most once.** `PendingIntentStore.Take` deletes the file before
  returning; stale (>2 min) and future-stamped notes are discarded.

## Autostart

One lane: a scheduled task triggered by the console user's logon, running as that
user at `RunLevel Highest`.

- On an admin console account, Highest starts DONUT elevated with no logon-time UAC
  prompt; on a non-admin account it degrades to the standard token.
- **An autostarted DONUT never elevates itself** — a tray start elevating would
  throw a consent (or credential) prompt at the sign-in screen. It runs de-elevated,
  says so once via toast when first surfaced, and elevation is whatever the user
  does next.
- **Every admin-only action is gated, including `startWithWindows`** — registering
  a scheduled task needs an elevated token, and `HomePresenter.ResumeGatedAction`
  re-runs the registration after the relaunch. The 120-second startup-task heal is
  not gated: it skips when de-elevated, because a background heal must never prompt.
- There used to be a SYSTEM+psexec autostart lane; deleting it fixed a bug. Do not
  reintroduce it — see
  [Design decisions](../decisions.md#the-deleted-system-autostart-lane).
  `tools\Diagnose-StartupTask.ps1` flags tasks left by older builds.

## Startup

`DonutApp.ps1` reads `runAsAdmin` **before it builds MainPresenter**, so an instance
about to hand over never warms a runspace pool it will discard, and relaunches
through `ElevationRelaunch::Spawn` (windowless on purpose, shared with the
presenter's spawn path).

The setting is never written from this path — a declined prompt leaves `runAsAdmin`
as it was, else one cancelled UAC would demote DONUT permanently. Only the Settings
toggle and the prompt's own "always" checkbox write it.

## One data root

`DonutPaths` resolves one machine-wide root at `%ProgramData%\DONUT\data` —
`config.json`, `recents.json`, the GitHub token, logs, and reports all hang off it,
secured on the run that creates it (SYSTEM, Administrators, the interactive user).
It is deliberately not `%LOCALAPPDATA%`: that is per-account, and a de-elevated UI
with privileged work under a different account would keep two of everything.

- `config.json` is therefore writable by the standard user while supplying DCU
  arguments to elevated remote runs — a real, accepted widening, and the price of a
  single shared store.
- The extracted app tree is **not** widened the same way (see
  [the first elevated launch](#the-first-elevated-launch)).
- The recents store (`RecentConnectionsStore`) persists per-host outcomes into its
  own `recents.json` — capped at 50, de-duplicated — so `config.json` stays
  settings-only and job traffic never rewrites it. Per-machine probe data lives in
  `reports\`, parsed on demand and memoized per session.

## The User Lens de-elevated

The [User Lens](./user-lens.md) runs its query through a de-elevated agent when
DONUT is elevated, because SCCM's AdminService and the BitLocker keys in AD are
scoped to the operator's regular account. De-elevated, DONUT already *is* that
account and the lookup runs in process.
