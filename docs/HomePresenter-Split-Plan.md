# HomePresenter Split — Design & Plan

Design note for splitting `src/UI/Presenters/HomePresenter.psm1` (1429 lines) into
cohesive coordinators, in the same spirit as the earlier `FinderPresenter`
extraction. It follows the architecture and testing conventions in
[`Refactoring_Proposal.md`](Refactoring_Proposal.md) and the comment/layout rules
in [`Coding-Style.md`](Coding-Style.md).

## Status

- **C# doc standardization — done.** The `src/Launcher/*.cs` **public API** is
  documented with XML doc comments to the standard codified in `Coding-Style.md`
  (§ *C# (`src/Launcher/`)*) — which follows Zephyr's scope: document the public
  API, don't restate the identifier, leave trivial members and internals alone.
- **HomePresenter split — complete (stages 1–5).** `InventoryPresenter` now owns
  the detail panel: header + overview render, the job log, the inventory / disk
  probe execution + completion, and machine selection. `HomePresenter` keeps the
  `AsyncJob` pump and a thin `StartInventory` reachability gate that hands online
  hosts to `$this.Detail.RunInventoryProbe`. Covered by
  `tests/Unit/InventoryPresenter.Tests.ps1`; build + lint + format + 522 Pester
  tests are green. **Still owed:** the manual UI pass on a live domain host
  (select a machine → inventory + biggest-folders render; refresh re-probes).

  Two deviations from the staged plan below, both to reduce churn/coupling:
  - `AppendLog*` + the `DetailLog` / `DetailProgress` controls moved in **stage 3**
    (with their probe-method callers), not stage 2 — they are driven by the probe
    lifecycle, so moving them in stage 2 would have rewritten ~35 call sites only to
    revert ~12.
  - **"Split the gate":** `StartInventory`'s reachability check (resolver verdict +
    `PendingGathers` queue + `PrefetchIp`) stays in `HomePresenter`; only the probe
    *execution* moved (`RunInventoryProbe`). This keeps the resolver/pump state with
    its owner and left `FinderPresenter`'s `StartInventory` seam unchanged.

## Motivation

`HomePresenter` is ~3× the next-largest presenter because it owns four only
loosely-related jobs. The 1429 lines already carry `# --- Section ---` dividers
that map cleanly onto candidate seams:

| Cluster | Rough lines | Responsibility | Shares the `AsyncJob` pump? |
| --- | --- | --- | --- |
| **Shell / list / search** | 202–654 | Build rows from WSID + recents, mode pill, Run/RunAll, host-window hook | — (owns it) |
| **Job lifecycle** | 655–1007 | `StartProcess`, poll/settle/complete, identity-mismatch + apply confirmation | **owns it** (`OnJobPolled`/`OnJobCompleted`) |
| **Rows** | 1008–1042 | `EnsureRow` / `GetRow` / `MoveRowToTop` | — |
| **Detail panel + inventory + disk** | 1043–1319 | Select machine, detail log, CIM inventory probe, WizTree "biggest folders", overview tiles | **yes** (`Inventory` / `DiskScan` job kinds) |
| **List housekeeping** | 1320–1429 | Clear-completed, empty hint, idle-time refresh, reboot detection | — |

The job pump (`AsyncJobPresenter` base + the lifecycle cluster) is the true core
of `HomePresenter` and stays put. The clean extraction target is the **detail
panel + inventory + disk** cluster.

## Precedent: the `FinderPresenter` seam

`FinderPresenter` was carved off `HomePresenter` and is the template to reuse:

- It is constructed with the shared collaborators **plus a duck-typed back-ref**
  to the owner:
  `[FinderPresenter]::new($config, $view, $HomeVm, $Logger, $toasts, $DialogPresenter, $this)`.
- It calls back into `HomePresenter`'s **machine seams** (`PrefetchIp`,
  `EnsureRow`, `StartInventory`, `MoveRowToTop`, `UpdateEmptyHint`) through that
  ref. A *typed* import would create a `using module` cycle, so the back-ref is
  intentionally `[object]`, not `[HomePresenter]`.
- It runs its **own** pool jobs on its **own** `DispatcherTimer`s, so it never
  touches the shared `AsyncJob` pump.

That last point is the difference the inventory split must handle.

## The constraint the split must respect: the shared pump

Unlike the finder, the inventory and disk probes are `AsyncJob`s of kind
`Inventory` / `DiskScan`, drained by `HomePresenter.OnJobCompleted` (line ~795),
which routes by `JobKind` to `CompleteInventory` / `CompleteDiskScan`. So the
cluster cannot simply move out and own its jobs the way the finder does — the
**pump ownership stays in `HomePresenter`**.

The seam is therefore *delegation*, not relocation of the pump:

```
# HomePresenter.OnJobCompleted (unchanged owner), routing by kind:
switch ($job.Kind) {
    'Inventory' { $this.Detail.CompleteInventory($job); break }
    'DiskScan'  { $this.Detail.CompleteDiskScan($job);  break }
    default     { <existing scan/apply/resolve handling> }
}
```

`InventoryPresenter` (working name; `DetailPresenter` is the alternative) owns the
detail-panel + inventory rendering; `HomePresenter` keeps owning the pump and
forwards the two job kinds to it — mirroring how `HomePresenter` already forwards
machine seams *into* `FinderPresenter`, but in the other direction.

## Proposed extraction: `InventoryPresenter`

**Moves out of `HomePresenter` into `src/UI/Presenters/InventoryPresenter.psm1`:**

- State: the detail-panel controls (`DetailEmptyHint`, `DetailContent`,
  `DetailHostText`, `DetailProbed`, `DetailRefreshButton`, `DetailLog`,
  `DetailProgress`, `FindFoldersButton`), the overview tiles (`Ov*`),
  `InventoryService`, `DiskUsageService`, and `InventoryTtl`.
- Methods: `SelectHost` / `SelectMachine` / `OnMachineSelectionChanged` /
  `ClearSelection`, `AppendLog` / `AppendLogLines`, `StartInventory` (both
  overloads) / `RefreshInventory` / `InventoryIsStale` / `CompleteInventory`,
  `FindBigFolders` / `CompleteDiskScan`, `RenderDetailSubtitle` /
  `PopulateDetailCards`, `RefreshOverview` / `UpdateOverviewTiles`.

**Stays in `HomePresenter`:** the pump, rows, list/search, housekeeping, and the
`Store` (recents) — `InventoryPresenter` reads/writes cached inventory through a
narrow `GetRecord` / persist seam rather than owning the store.

**Shared state to thread through the seam** (constructor args + back-ref, the
`FinderPresenter` shape):

- Read-only collaborators: `$Config`, `$Logger`, `$Toasts`, `$HomeVm`,
  `$InventoryService`, `$DiskUsageService`, `$Store`.
- Back-ref `[object] $Home` for: enqueuing probes on the pump
  (`$Home.StartPoolJob(...)` / the existing `AsyncJob` enqueue path),
  `GetRecord`, `GetRow`, `SelectedHost` get/set, and `UpdateEmptyHint`.
- `SelectedHost` has a single owner. Keep it on `HomePresenter` and let
  `InventoryPresenter` read/write it via the back-ref, so row-click (Home) and
  detail rendering (Inventory) never disagree.

## Staged migration

Each step was independently compilable + testable; committed per step. **All done.**

1. **Scaffold `InventoryPresenter` (the seam), inert. — *Done.*** The class,
   constructor, and duck-typed `$Home` back-ref, registered in `HomePresenter`'s
   `using module` graph and constructed with an empty `Initialize`. Zero behavior
   change; validated the parse-graph placement (the architecturally risky part).
2. **Move the detail controls + pure render helpers. — *Done.*** The detail-header +
   overview control fields and `FindName` lookups, plus `PopulateDetailCards`,
   `RenderDetailSubtitle`, `RefreshOverview`, `UpdateOverviewTiles`. `AppendLog*`
   was **deferred to stage 3** (see the deviation note under *Status*).
3. **Move the probe lifecycle. — *Done.*** `RunInventoryProbe` (the execution half
   of `StartInventory`), `CompleteInventory`, `FindBigFolders`, `CompleteDiskScan`,
   `RefreshInventory`, `InventoryIsStale`, and `AppendLog*` + the `DetailLog` /
   `DetailProgress` controls and probe buttons; `OnJobCompleted` now delegates the
   `Inventory` / `DiskScan` kinds. `HomePresenter` keeps `StartInventory` as the
   reachability gate ("split the gate", see *Status*).
4. **Move selection. — *Done.*** `SelectHost`/`SelectMachine`/
   `OnMachineSelectionChanged`/`ClearSelection`; repointed the `MachineList`
   selection-changed handler. `FinderPresenter`'s `StartInventory` seam needed no
   change because the gate stayed in `HomePresenter`.
5. **Tests + cleanup. — *Done.*** No pass-throughs remained (callers were repointed
   to `$this.Detail` directly); added `tests/Unit/InventoryPresenter.Tests.ps1`.

Outcome: `HomePresenter` 1439 → ~1140 lines, `InventoryPresenter` ~380. (Above the
900-1000 / 300-350 estimate because "split the gate" kept the gate in `HomePresenter`
and `InventoryPresenter` owns more of the selection + log path than first scoped.)

## Test gates

- **Unit (must stay green):** `tests/Unit/InventoryService.Tests.ps1`,
  `MachineInventory.Tests.ps1`, `DiskUsage.Tests.ps1`, `RecentConnection.Tests.ps1`,
  `AsyncJobPresenter.Tests.ps1`. The probe *logic* already lives in the tested
  services/models; the split only moves the presenter glue, so these guard the
  contract.
- **New unit coverage:** an `InventoryPresenter.Tests.ps1` that fakes the services
  and asserts `CompleteInventory` populates the overview tiles and that a stale
  vs. fresh record drives the re-probe decision (mirror the existing presenter
  tests' mock-the-service approach).
- **Lint/format gate:** `tools/Invoke-Lint.ps1` and `tools/Invoke-Format.ps1 -Check`.
- **Manual (Windows):** select a machine → inventory + biggest-folders render;
  refresh re-probes; the finder's "add to list then inventory" path still works.

## Risks & rollback

- **Pump routing regression** — an `Inventory`/`DiskScan` job whose completion no
  longer reaches its handler shows as a detail panel that never fills. Caught by
  the manual check + a completion assertion in the new test. Mitigation: step 3
  changes routing in isolation.
- **`using module` cycle** — importing `HomePresenter` into `InventoryPresenter`
  (or vice-versa) for a typed field. Avoided by the same `[object]` back-ref the
  finder uses; do **not** add a typed import.
- **Two owners of `SelectedHost`** — avoided by keeping it solely on
  `HomePresenter`.
- **Rollback:** each stage is a standalone commit; revert the last green step.

## Deliberately *not* split (yet)

The **host-resolution / warm** cluster (`StartWarm`, `WarmPool`, `PrefetchIp`,
`CompleteResolve`, `StartVerifyName`, …) is also pump-coupled (`Resolve` job
kind) and is a plausible second extraction (`ResolutionCoordinator`). It is left
for a follow-up: `HostResolver` already holds the cache logic, so the presenter
glue is thinner and the payoff smaller than the inventory cluster. Splitting one
cluster at a time keeps each change reviewable — the same rule `Refactoring_Proposal.md`
applies to naming churn.
