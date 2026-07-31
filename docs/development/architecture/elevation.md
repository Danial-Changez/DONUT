---
title: Elevation and autostart
description: How DONUT decides whether it is elevated, when it relaunches itself, and why autostart no longer runs as SYSTEM.
---

DONUT is a fleet management app for Dell workstations, and every remote operation it
performs authenticates as the DONUT process itself. That one fact drives the whole
elevation model: de-elevated, DONUT is the console user, who has no administrative rights
on fleet targets.

![Configuration and persistence class diagram](/diagrams/class_config.svg)

*Source: [`class_config.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_config.puml)*

## The model

- **`asInvoker`, not `requireAdministrator`.** The launcher manifest no longer demands
  elevation, so DONUT opens as whatever account started it. It relaunches itself when it
  needs more.
- **`ElevationContext` is the only place that reads the token.** `IsElevated` asks whether
  the process carries the Administrators group; `IsSystem` is the narrower service-token
  question. `Classify` is the pure rule the UI gates on, returning `NotRequired`,
  `Satisfied` or `RelaunchRequired`. It takes the elevation state as a parameter, so the
  decision is unit-testable on any platform while the Win32 read stays two lines.
- **`runAsAdmin` defaults to `true`.** It is the only boolean setting that falls back to
  `true` on a missing or corrupt value, because the failure mode of guessing wrong is an
  app where nothing remote works.
- **One prompt per session, never per action.** Elevating relaunches the whole UI, so once
  it succeeds every gate is open for the life of the process.

## Relaunching

`MainPresenter.RestartElevated` and `EnsureElevated` share one `SpawnElevated`, and the
order is load-bearing:

1. Persist anything that must survive the swap.
2. `Start-Process -Verb RunAs`. **The prompt comes before any teardown** - a declined UAC
   has to leave a fully working app.
3. Only on success set `ExitRequested` and close the window.

A declined prompt raises `Win32Exception` 1223 (`ERROR_CANCELLED`). The toggle path reverts
the setting; a gated action discards its note and undoes a remembered choice, so a decline
does not reappear at every launch.

**Note:** turning `runAsAdmin` off cannot take effect in place. Windows has no un-elevate
API, so it applies at the next launch and the UI says so.

**The single-instance mutex is `Local\`-scoped, which is per-session and not per-token.**
An elevated relaunch therefore collides with the de-elevated instance that spawned it and
would bow out as a "second instance". Both hosts wait the predecessor out first:
`--await-pid` in the launcher, handled before the mutex block, and `-AwaitPid` in
`Start-Donut.ps1` for the dev path.

## Gated actions

Scan, apply, inventory, storage scan, clear selected and the Start with Windows toggle all
need administrator rights. Clicking one while de-elevated records what was clicked,
elevates, and re-runs it.

- **`PendingIntent` is untrusted input.** A de-elevated process writes it and an elevated
  one reads it, so it carries only an action kind and host names, never paths or
  arguments. `FromJson` matches the action against the enum *names*, not
  `[enum]::TryParse`, which accepts a numeric string and would map `{"action":3}` onto
  whatever member sits at ordinal 3.
- **`DeleteFolders` is never resumed.** Its folder list lives in the window's selection and
  cannot be rebuilt from the note, and it is the one destructive action, so the user
  re-picks after elevating.
- **A note fires at most once.** `PendingIntentStore.Take` deletes the file before it
  returns anything, so a resume that then throws cannot re-fire on every launch. Stale
  notes (older than two minutes) and future-stamped ones are discarded.

## Autostart

One lane: a scheduled task triggered by the console user's logon, running as that user at
`RunLevel Highest`.

- **Highest, not Limited.** Both run as the console user; the difference is only which of
  that account's tokens the task receives. On an **admin** console account Highest starts
  DONUT elevated with no logon-time UAC prompt. On a **non-admin** console account it has no
  effect at all: it degrades to that account's standard token.
- **An autostarted DONUT never elevates itself.** `runAsAdmin` is honoured at startup
  (below), but a tray start is the deliberate exception: elevating there would throw a
  consent prompt - or, from a standard account, a *credential* prompt - at the sign-in
  screen. It runs de-elevated and says so through `MainPresenter.PendingLimitedNotice`, one
  toast the first time the window is surfaced from the tray. Elevation is then whatever the
  user does next: any gated action, or the **Run as administrator** toggle.
- **It does not resurrect the deleted lane.** The principal is the console user either way.
  What was broken below was the SYSTEM principal, not the run level.

## Startup

`app.manifest` is `asInvoker`, so nothing elevates DONUT for free. `DonutApp.ps1` reads
`runAsAdmin` **before it builds MainPresenter**, so an instance about to hand over never
warms a runspace pool it is going to discard, and relaunches through
`ElevationRelaunch::Spawn`.

- **The setting is never written from this path.** A declined prompt leaves `runAsAdmin`
  exactly as it was; otherwise one cancelled UAC would demote DONUT permanently and it would
  never try again. Only the Settings toggle and the prompt's own "always" checkbox write it.
- **`ElevationRelaunch` is windowless on purpose** (`src/Core/ElevationRelaunch.psm1`), so
  the startup check and `MainPresenter.SpawnElevated` share one spec builder and one spawn.
  The presenter adds only its own teardown.
- **Every admin-only action is gated, including `startWithWindows`.** Registering a
  scheduled task needs an elevated token; ungated, the toggle reached
  `Register-ScheduledTask`, took an access-denied, and reported it as a single toast while
  the setting still read on. `HomePresenter.ResumeGatedAction` re-runs the registration after
  the elevated relaunch. The 120-second startup-task **heal** is not gated - it skips
  entirely when de-elevated, because a background heal must never prompt.

**There used to be a second lane, and deleting it fixed a bug rather than only simplifying
the code.** A task cannot start an elevated process as an account that is not an admin: an
Interactive principal needs a logon session a separate admin account does not have, and
`RunLevel Highest` on a non-admin console user degrades to a standard token. So autostart
registered a SYSTEM task that relaunched DONUT into the console session through psexec.
That worked, and it was broken: as SYSTEM the instance authenticates on the network as the
**machine account**, which has no rights on fleet targets, so the autostarted DONUT painted
a working UI and then failed every remote job on access denied. Do not reintroduce it.

- **The trigger is always the console user.** A task triggered by an account that never
  logs on stays `Ready` forever: no run, no error, nothing in any log. Under
  over-the-shoulder UAC the elevated DONUT shares the signed-in user's session, so the
  desktop owner is the account to bind to, not the token's.
- **Never derive the run-as account from `$env:`.** Under SYSTEM that names a nonexistent
  account and Task Scheduler rejects it with "No mapping between account names and
  security IDs".
- **Registering a task still needs elevation**, so the toggle is gated like any other admin
  action.

`tools\Diagnose-StartupTask.ps1` reports the registered principal, trigger and last result,
and flags a SYSTEM principal or a psexec action as a task left by an older build.

## One data root

Everything user-scoped used to hang off `%LOCALAPPDATA%`, which is per-account. With a
de-elevated UI and privileged work under a different account that splits into two stores:
two `config.json` files, two GitHub tokens, two log folders. `DonutPaths` resolves one
machine-wide root at `%ProgramData%\DONUT\data` instead. See
[Configuration and persistence](./configuration-and-persistence.md).

**Note:** `config.json` is therefore writable by the standard user, and it supplies DCU
arguments to elevated remote runs. That is a real, accepted widening of what a compromised
user session can influence, and the price of a single shared store.

The extracted app tree at `%ProgramData%\DONUT\app` is deliberately **not** widened the
same way. It is the `src\` an elevated DONUT executes, so granting non-admins write access
there would be a local privilege escalation. De-elevated runs only need read and execute.

## The User Lens de-elevated

The [User Lens](./user-lens.md), DONUT's user-to-device lookup, runs its query through a
de-elevated agent when DONUT is elevated, because SCCM's AdminService and the BitLocker
keys in AD are scoped to the operator's regular account. De-elevated, DONUT already *is*
that account, so `PersonLensService.RunLookupJson` calls the lookup in process and skips
the agent, its scheduled task, the encrypted exchange and the heartbeat entirely. The
trade-off is that the in-process path emits no partials, so the pane fills in one step
rather than progressively.
