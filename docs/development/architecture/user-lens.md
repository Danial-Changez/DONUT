---
title: User Lens (de-elevation)
description: Why the User Lens runs as a de-elevated agent, the encrypted exchange protocol, and the AD/SCCM query design.
---

The User Lens is DONUT's user-to-device lookup panel (the name comes from an
internal tool). This page covers why it runs de-elevated and how the agent works;
the feature itself is described in [User Lens](../../features/user-lens.md).

![Lens class diagram](/diagrams/class_lens.svg)

*Source: [`class_lens.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_lens.puml)*

## Why de-elevated

When elevated, DONUT runs as an admin account (required for the psexec/CIM remote
work), but the Lens data is only readable by the operator's regular account:

- The person-to-device mapping and hardware inventory come from SCCM, whose
  AdminService is RBAC-scoped to the regular account, not the admin one.
- BitLocker recovery keys sit in AD under the computer object with the same
  scoping.
- Elevating does not grant the regular account's rights - a separate identity
  means a separate process.

**The agent is only needed when DONUT is elevated.** De-elevated, DONUT already *is* the
interactive user whose rights this data needs, so `PersonLensService.RunLookupJson` calls
the same `Resolve-Lens` in process and skips the agent, its scheduled task, the encrypted
exchange and the heartbeat. `Resolve-Lens` returns the bundle and only writes
`result-<id>.bin` when it has a request id and an exchange directory. The trade-off is that
the in-process path emits no partials, so the pane fills in one step rather than
progressively. See [Elevation and autostart](./elevation.md).

## The persistent agent

- A single `LensAgent.ps1` runs de-elevated as the interactive user for the
  app's whole lifetime, started via a scheduled task (`LogonType Interactive` =
  the logged-on token, no password; `RunLevel Limited` = medium integrity; action
  wrapped in `conhost.exe --headless` so no console window flashes).
  `Shell.Application` was tried and rejected - it only de-elevates within the
  same user.
- `FinderPresenter.WarmLens` starts it on the pool at app startup
  (fire-and-forget, parallel with the pool/AD warm), so it pre-warms its AD/SCCM
  libraries while DONUT boots. Even the first pick skips the per-lookup task
  registration + `pwsh` cold start (~2-4 s) the previous one-shot-task design
  paid every time.
- `PersonLensService` is the agent's supervisor + client, and stays
  **transport-only** - it never queries AD or SCCM itself. `EnsureAgent`
  (mutex-guarded against concurrent pool runspaces) treats a `heartbeat.txt`
  older than 15 s as a dead agent and re-registers the task; `RunLookupJson`
  drives one lookup over the exchange.
- The agent beats from a background thread (not the serve loop), so a lookup in
  flight - which blocks the serve loop for tens of seconds - never lets the beat
  go stale and get the busy agent torn down mid-lookup. It self-exits when
  DONUT's process dies (a `-ParentPid` watchdog), when a `stop.flag` appears, or
  when the exchange dir is purged.
- A lookup is offloaded to a `ThreadJob` so a slow one never blocks the serve
  loop.
- **Note:** the AD finder search runs in-process on the pool, **not** through
  this agent: `FinderPresenter` fans out one `AdSearchWorker` job per forest,
  each calling `ActiveDirectoryService.Search` as the elevated admin - AD reads
  don't need de-elevation. (Routing it through the agent was tried and dragged
  the agent's cold start onto the per-keystroke path, freezing the UI.)

## Query design (Resolve-Lens)

`Resolve-Lens` in `LensAgent.Common.ps1` is the data-access composition point -
a future source (e.g. an Intune API) slots in beside the existing ones here:

1. The AD user read runs forest-wide via the Global Catalog (`GC://...`, then a
   home-domain bind for the full attribute set).
2. The SCCM affinity query (person to WSIDs, `SMS_UserMachineRelationship`) runs
   on a thread job in parallel with the AD read.
3. A hardware-inventory pass (model/serial/manufacturer via
   `SMS_G_System_COMPUTER_SYSTEM` / `SMS_G_System_PC_BIOS`, keyed by the affinity
   row's `ResourceID`) runs on a second thread job in parallel with the
   per-device AD loop.
4. Everything else per-device (OS, last logon, BitLocker keys) is read from the
   computer's AD object.

- **Note (AdminService filter shapes):** the `/wmi` route's OData translator
  rejects richer string filters (`or`, backslashes) with 404. The affinity query
  filters on the forest-unique SAM with `endswith` and exact-matches
  client-side, so no `DOMAIN\sam` backslash ever enters the URL; the hardware
  pass filters on
  `ResourceID eq N`, falls back once to the keyed segment `Class(N)` if the
  filter shape is rejected, and never uses a string filter.
- **Note (a rejected filter has two shapes):** a site that will not serve the
  filter form answers either 404 **or** 200 with an empty set. Both fall through
  to the keyed segment, and a device that comes back empty from both records
  `no inventory rows for ResourceID N` rather than a blank card. Treating only
  the 404 as rejection is what made model and tag silently absent.
- **Note (interpolating a class into the path):** the URL builder writes
  `${class}?` with braces. `"$class?"` parses `class?` as the variable name, so
  the class vanishes from the path and the query matches nothing, silently.
- **Note (the affinity query runs both ways):** the person direction filters
  `endswith(UniqueUserName, sam)` because a `UniqueUserName` carries a domain
  backslash. The machine direction (`Resolve-MachineOwnerBatch`, used for the name
  on a machine card) filters `ResourceName eq '<wsid>'`, which this AdminService
  serves. SCCM returns an account name; **`SMS_R_User.FullUserName` then names the
  person** - User Discovery's copy of `displayName`, and the reason it comes first:
  the site aggregates users from **every** forest, while `Find-Gc` reads the agent's
  own forest's GC and can never name a sibling-forest user. That gap is exactly how
  owner chips shipped showing SAMs. The GC stays as the fallback for its one forest,
  the SAM stands in when both reads fail, and resolved names memoize per agent
  session (`OwnerNameCache`) so a shared owner is named once. The card shows
  `HOST (Danial C)` - first name + surname initial, full display name in the tooltip.
- **The owner lookup is one batched request, not one per machine.** The serve loop
  answers it inline and sleeps 150ms between passes, so N separate requests would
  cost N sleeps plus N files, N AES round trips and N parent polls - slower than
  resolving them back to back, while holding N of the four interactive runspaces.
  Parent-side fan-out would buy no throughput against a serially-served agent.
  `RecentConnectionsStore.UpsertOwner` caches the answer so it is asked once.
- A failed source degrades: each appends to the bundle's `errors` list and the
  lens still renders (blank hardware fields, missing keys noted per device).
- The parse (`PersonLens.FromJson`) is pure and unit-tested; the agent/task I/O
  is the overridable `RunLookupJson` seam.

## The exchange protocol

Fixed `%ProgramData%\DONUT\lens-agent` dir:

1. The parent drops `request-<id>.bin`.
2. The agent answers `partial-<id>-1.bin` (directory facts), then
   `partial-<id>-2.bin` (name-only device rows), then `result-<id>.bin` (the
   filled detail) - so the UI paints progressively.
3. Each side deletes what it consumed; the agent sweeps anything older than 10
   minutes.

## Securing the exchange

The bundle holds BitLocker recovery keys:

- The exchange folder's inherited ACL is stripped (ProgramData grants all local
  users read) down to SYSTEM / Administrators / the interactive user.
- Every payload is AES-256-CBC encrypted with a per-session key minted when the
  agent starts (`key.bin`, 32-byte key + 16-byte IV;
  `PersonLensService.ProtectText`/`UnprotectText`/`WriteEncrypted` are the
  unit-tested twins of the agent's inline crypto). Nothing touches disk in the
  clear. The ACL-locked dir is the real boundary; the key is defense-in-depth.
- On window close the parent drops `stop.flag`, stops + unregisters the task,
  and deletes every `lens-*` dir. The per-person UI cache is memory-only
  (`FinderPresenter.LensCache`, 15-min TTL), so it dies with the process.
