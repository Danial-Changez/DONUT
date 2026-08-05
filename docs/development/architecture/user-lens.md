---
title: User Lens (de-elevation)
description: Why the User Lens runs as a de-elevated agent, the encrypted exchange protocol, and the AD/SCCM query design.
---

The User Lens is DONUT's user-to-device lookup panel. This page covers why it runs
de-elevated and how the agent works; the feature itself is described in
[User Lens](../../features/user-lens.md).

![Lens class diagram](/diagrams/class_lens.svg)

*Source: [`class_lens.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_lens.puml)*

## Why de-elevated

Elevated, DONUT runs as an admin account, but the Lens data is only readable by the
operator's regular account: SCCM's AdminService is RBAC-scoped to it, and the
BitLocker keys in AD carry the same scoping. Elevation does not grant a different
identity's rights — a separate identity means a separate process.

The agent is only needed when DONUT is elevated. De-elevated, DONUT already *is*
the right identity, so `PersonLensService.RunLookupJson` calls `Resolve-Lens` in
process and skips the agent, task, crypto, and heartbeat entirely; the trade-off is
no partials, so the pane fills in one step. See
[Elevation and autostart](./elevation.md).

## The persistent agent

- One `LensAgent.ps1` runs de-elevated as the interactive user for the app's whole
  lifetime, started via a scheduled task: `LogonType Interactive` (the logged-on
  token, no password), `RunLevel Limited`, wrapped in `conhost.exe --headless` so no
  console window flashes.
- `FinderPresenter.WarmLens` starts it at app startup (fire-and-forget), so it
  pre-warms its AD/SCCM libraries while DONUT boots — even the first pick skips a
  task registration + `pwsh` cold start.
- `PersonLensService` is the supervisor + client and stays **transport-only** — it
  never queries AD or SCCM itself. `EnsureAgent` (mutex-guarded) treats a
  `heartbeat.txt` older than 15 s as a dead agent and re-registers the task.
- The agent beats from a background thread, not the serve loop, so a lookup in
  flight never lets the beat go stale and get the busy agent torn down mid-lookup.
  Lookups run on a `ThreadJob` so a slow one never blocks the serve loop. It
  self-exits on a `-ParentPid` watchdog, a `stop.flag`, or a purged exchange dir.
- The AD finder search does **not** route through this agent — it fans out
  in-process on the pool (AD reads don't need de-elevation). Rejected designs are
  in [Design decisions](../decisions.md#rejected-agent-designs).

## Query design (Resolve-Lens)

`Resolve-Lens` in `LensAgent.Common.ps1` is the data-access composition point — a
future source (e.g. an Intune API) slots in beside the existing ones:

1. The AD user read runs forest-wide via the Global Catalog, then a home-domain
   bind for the full attribute set.
2. The SCCM affinity query (person → WSIDs, `SMS_UserMachineRelationship`) runs on
   a thread job in parallel with the AD read.
3. A hardware-inventory pass (model/serial/manufacturer, keyed by the affinity
   row's `ResourceID`) runs on a second thread job in parallel with the per-device
   AD loop.
4. Everything else per-device (OS, last logon, BitLocker keys) reads from the
   computer's AD object.

Rules the AdminService imposes (each learned the hard way — see
[Design decisions](../decisions.md#adminservice-filter-shapes)):

- The affinity query filters on the forest-unique SAM with `endswith` and
  exact-matches client-side — no `DOMAIN\sam` backslash ever enters the URL.
- The hardware pass filters `ResourceID eq N`, falls back once to the keyed segment
  `Class(N)`, and never uses a string filter.
- A rejected filter answers 404 **or** 200-empty; both fall through to the keyed
  segment, and a device empty from both records `no inventory rows for ResourceID
  N` rather than a blank card.
- Owner naming: `SMS_R_User.FullUserName` first (the site aggregates every forest),
  the agent's own-forest GC as fallback, the SAM as last resort; names memoize per
  agent session, and the batched owner lookup is one request for all machines.

A failed source degrades: each appends to the bundle's `errors` list and the lens
still renders. The parse (`PersonLens.FromJson`) is pure and unit-tested; the
agent/task I/O is the overridable `RunLookupJson` seam.

## The exchange protocol

Fixed `%ProgramData%\DONUT\lens-agent` dir:

1. The parent drops `request-<id>.bin`.
2. The agent answers `partial-<id>-1.bin` (directory facts), `partial-<id>-2.bin`
   (name-only device rows), then `result-<id>.bin` (the filled detail) — so the UI
   paints progressively.
3. Each side deletes what it consumed; the agent sweeps anything older than 10
   minutes.

## Securing the exchange

The bundle holds BitLocker recovery keys:

- The exchange folder's inherited ACL is stripped down to SYSTEM / Administrators /
  the interactive user.
- Every payload is AES-256-CBC encrypted with a per-session key minted when the
  agent starts (`key.bin`; `PersonLensService.ProtectText`/`UnprotectText` are the
  unit-tested twins of the agent's inline crypto). Nothing touches disk in the
  clear. The ACL-locked dir is the real boundary; the key is defense-in-depth.
- On window close the parent drops `stop.flag`, stops + unregisters the task, and
  deletes every `lens-*` dir. The per-person UI cache is memory-only
  (`FinderPresenter.LensCache`, 15-min TTL), so it dies with the process.
