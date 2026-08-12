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
- `FinderPresenter.WarmLens` starts it at app startup (fire-and-forget), and the
  agent pre-warms on a thread job while DONUT boots — the GC and home-domain
  binds plus throwaway AdminService affinity and hardware queries, so even the
  first pick reuses warm connections on every path — and the serve loop starts
  serving before the warm lands.
- `PersonLensService` is the supervisor + client and stays **transport-only** — it
  never queries AD or SCCM itself. `EnsureAgent` (mutex-guarded) treats a
  `heartbeat.txt` older than 15 s as a dead or wedged agent and re-registers the
  task; two lookup timeouts in a row (`timeouts.txt`) force the same recycle even
  while the beat stays fresh, which catches an agent poisoned by dead binds after
  sleep.
- The serve loop itself beats every ~2 s and never blocks: person lookups and
  owner batches run on `ThreadJob`s (any job stuck past 90 seconds is cut loose,
  since the parent stops listening at 60 and a straggler only hogs a throttle slot),
  so a fresh beat proves requests are being read and a stale one means dead or
  wedged either way. It self-exits on a `-ParentPid` watchdog, a `stop.flag`, or a
  purged exchange dir.
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
  batch, and the batched owner lookup is one request for all machines, served on a
  thread job off the serve loop.
- The software list (`Resolve-UserSoftware`, request kind `software`) walks the user
  direction: `SMS_R_User` names the ResourceIDs (endswith, exact tail client-side),
  `SMS_FullCollectionMembership` the collections (`ResourceID eq N`, with no keyed
  fallback for its compound key), then one `$select`-trimmed `SMS_DeploymentSummary`
  fetch is filtered client-side to install-intent applications plus every package
  deployment (packages carry their program name, since no generic filter can sort
  them apart) — an or-filter over the collections would 404. It rides its own
  request, dispatched in parallel with the person lookup, so neither ever waits on
  the other; the optional `lensSoftwareCollectionFilter` config regex narrows the
  rows parent-side at render time, blank by default.
- Every AdminService call carries a 15 s timeout and every searcher a 15 s
  `ClientTimeout`, so an unreachable site or DC fails a lookup instead of wedging
  the agent.

The final bundle also carries a `timings` map — cumulative milliseconds at each
gather stage (user read, affinity collect, device loop, hardware merge) — which
debug logging prints beside the parent's queued/total numbers, so a slow pick can
be attributed to a stage rather than argued about.

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
4. The parent counts consecutive lookup timeouts in `timeouts.txt` (no secrets,
   just a counter); a completed lookup deletes it, and at two `EnsureAgent`
   recycles the agent.

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
