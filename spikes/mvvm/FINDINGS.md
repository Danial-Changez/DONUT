<h1> Spike: Is a move from MVP to MVVM feasible in DONUT? </h1>

**TL;DR — Yes, MVVM is technically feasible in this PowerShell + WPF app, but *not*
via PSCustomObjects.** The viable route is a tiny C# `ObservableObject`
(`INotifyPropertyChanged`) base — which fits naturally because the app already ships a
C# `Donut.Launcher` project — with PowerShell view-model classes inheriting it. A full
migration is a **large** rewrite, so the recommendation is an **incremental pilot**
(start with the machine list), not a big-bang conversion.

This spike is proof-of-concept only; nothing here is wired into `src/`.

<h2> How to reproduce </h2>

```powershell
pwsh -Sta -File spikes/mvvm/Test-Mvvm.ps1
```

It shows **no window** — it creates WPF controls, applies real bindings, mutates the
sources, pumps the dispatcher, and reads the control values back. Files:

- [`ObservableObject.cs`](ObservableObject.cs) — the minimal MVVM base (what you'd add to `Donut.Launcher`).
- [`Test-Mvvm.ps1`](Test-Mvvm.ps1) — bootstrap: loads WPF + the C# base, then runs the body.
- [`Spike-Body.ps1`](Spike-Body.ps1) — a PowerShell view-model + the binding experiments.

<h2> Results (measured, headless) </h2>

| # | Capability | Result | What it means |
|---|------------|--------|---------------|
| 1 | PSCustomObject → one-way binding (read) | **PASS** | WPF *can* read `PSCustomObject`/`PSObject` note-properties for display. |
| 2 | PSCustomObject → live update on property change | **FAIL** *(expected)* | Changing a note-property does **not** update the UI — `PSObject` raises no `INotifyPropertyChanged`. |
| 3 | PS view-model (`: ObservableObject`) → initial read | **PASS** | PS class fields compile to real CLR properties; WPF binds to them. |
| 4 | PS view-model → live UI update via `PropertyChanged` | **PASS** | Calling the inherited `Raise('Status')` after a change updates the bound control. **This is the core of MVVM.** |
| 5 | PS view-model → two-way (UI edit pushes back to model) | **PASS** | `Mode=TwoWay, UpdateSourceTrigger=PropertyChanged` writes the control value back into the view-model. |
| 6 | `ObservableCollection` → `ItemsControl.ItemsSource` auto-updates | **PASS** | Add/remove on the collection updates the list live (`1 → 3 → 2`) with no imperative code. |
| 7 | Data-bound list can virtualize | **PASS** | A `ListBox`/`VirtualizingStackPanel`-backed items panel virtualizes by default. |

<h2> The verdict on each approach </h2>

### ❌ PSCustomObjects alone — not enough
WPF happily *reads* `PSCustomObject` properties (test 1), so they're fine for
**static, rebuilt-each-time** display. But they cannot raise change notifications
(test 2), so any UI that needs to react to model changes — which is most of DONUT's
Home screen — would still be driven imperatively. PSCustomObjects do **not** unlock MVVM.

### ✅ C# `ObservableObject` base + PowerShell view-models — works
PowerShell classes **cannot declare CLR events**, so they can't implement
`INotifyPropertyChanged` themselves. But they **can inherit** a .NET base that provides
the `PropertyChanged` event and a `Raise()` helper (tests 3–5). Since the app already
compiles [`Donut.Launcher`](../../src/Launcher/), dropping a ~15-line `ObservableObject`
(and a small `RelayCommand` for `ICommand`/button binding) there is trivial and keeps
one source of truth.

**The one ergonomic tax:** PowerShell classes have no property *setters*, so a
view-model can't auto-raise on assignment. Mutations go through a helper:

```powershell
class HostViewModel : ObservableObject {
    [string] $Status
    [void] Set([string]$prop, $value) { $this.$prop = $value; $this.Raise($prop) }
}
# usage:  $vm.Set('Status', 'Scanning')   instead of   $vm.Status = 'Scanning'
```

That's the whole difference from idiomatic C# MVVM. Everything else (bindings,
`ObservableCollection`, `DataTemplate`, `HierarchicalDataTemplate`, converters,
virtualization) is standard WPF and works from PowerShell.

<h2> Benefits of MVVM over the current MVP — for *this* codebase </h2>

1. **Deletes most of the imperative UI code.** [`HomePresenter.psm1`](../../src/UI/Presenters/HomePresenter.psm1)
   is ~1,730 lines, much of it `FindName` + poke: `SetStatus`, `SetPercent`,
   `UpdateOverviewTiles`, `PopulateDetailCards`, and hand-built visual trees
   (`RenderBigFolders`/`BuildFolderTreeItem`, `BuildSearchRow`, and the whole
   [`ConnectionRow`](../../src/UI/Presenters/ConnectionRow.psm1) that assembles Borders/Grids
   in code). Under MVVM these become XAML `DataTemplate`s bound to view-model properties.

2. **Unlocks list virtualization for free — the exact win flagged in the perf review.**
   The machine list is today an `ItemsControl` with realized `ConnectionRow.Root`
   elements `.Add()`ed imperatively ([HomeView.xaml](../../src/UI/Views/HomeView.xaml) +
   [EnsureRow](../../src/UI/Presenters/HomePresenter.psm1)), so it **cannot virtualize**.
   Switching to `ItemsSource={Binding Machines}` + a `DataTemplate` on a virtualizing
   panel (test 6 + 7) gives virtualization with no extra work. MVVM is the clean path to
   that pagination/virtualization item.

3. **The folder tree gets simpler, not harder.** `DiskUsageTree` already produces a
   nested `FolderTreeNode` graph; a `HierarchicalDataTemplate` binding `Children` renders
   it declaratively, replacing the recursive `BuildFolderTreeItem`/`BuildFolderHeader`.

4. **Reactive status instead of manual refresh.** A job progresses → `vm.Set('Percent', p)`
   and the bar updates itself; the overview tiles bind to the selected machine's view-model
   instead of `UpdateOverviewTiles()` re-poking eight `TextBlock`s each tick.

5. **The pure mappers are already MVVM-shaped.** `FleetStatus`, `DcuProgress`,
   `InventoryFormat`, `DiskUsageFormat`, `TimeFormat` are pure decision/format functions —
   they become `IValueConverter`s or computed view-model properties almost verbatim, and
   stay unit-tested. DONUT's MVP already did the hard part (extracting logic off the view).

6. **Testability parity, slightly better.** View-models are directly state-testable
   without WPF. (MVP already gets most of this via the passive view + pure mappers, so
   this is an incremental, not transformational, gain.)

<h2> Costs / risks </h2>

- **It's a large rewrite.** Every view needs XAML bindings + `DataTemplate`s and every
  presenter becomes a view-model. `HomePresenter` alone is a big surface.
- **Threading is unchanged.** The runspace-pool + `DispatcherTimer` polling that drains
  each `AsyncJob`'s `ConcurrentQueue` still exists — MVVM only changes how the *result*
  reaches the UI (set a VM property vs. call a control method). All the freeze fixes in the
  git history (pump re-entrancy, warm-before-show, off-thread probes) still apply.
- **PS-class ergonomics:** no property setters (the `Set()` tax), and you need small C#
  helpers (`ObservableObject`, `RelayCommand`) for events/commands.
- **Regression risk:** the current MVP is battle-tested; a broad conversion risks
  reintroducing solved UI-thread bugs. Collection updates must happen on the UI thread.
- **`ObservableCollection` marshalling:** background code can't add to a bound collection
  off-thread — additions must be marshalled to the dispatcher (the presenter already runs
  completion work on the dispatcher, so this fits, but it's a rule to hold).

<h2> Recommendation </h2>

**Feasible and worth piloting — incrementally, not all at once.**

1. Add `ObservableObject` (+ a small `RelayCommand`) to `Donut.Launcher`.
2. Convert **one** high-value surface as a pilot: the **machine list** → `ObservableCollection<HostViewModel>` + a `DataTemplate` on a virtualizing panel. This
   simultaneously (a) proves the ergonomics in-app and (b) delivers the list-virtualization
   perf win. Keep `ConnectionRow`'s logic as the view-model.
3. Reuse the existing pure mappers as converters/computed properties.
4. Evaluate the pilot's ergonomics (especially the `Set()` tax and dispatcher
   marshalling) before deciding on a full migration. MVP and MVVM can coexist during the
   transition — the shell stays MVP while individual views move to MVVM.

Net: MVVM won't fix anything that's *broken* today, but it would remove a large amount of
imperative view code and is the natural enabler for list virtualization. The blocker is
effort/risk, not technical possibility — the possibility is now demonstrated.
