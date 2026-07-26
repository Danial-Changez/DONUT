# HomeView split: shell + region component files

**Status: landed** (branch `refactor/homeview-split`, 2026-07-25).

## Why

HomeView.xaml was a 1,065-line monolith left over from the multi-page navbar era
(`4f4202f` deleted the sidebar; Home became the only page). The presenter layer had
already split (`HomePresenter` → `InventoryPresenter` / `FinderPresenter` /
`ResolutionCoordinator`) but the XAML never followed — the detail pane alone was 588
lines, and every presenter FindNamed into one shared namescope.

The seams were already clean: region ↔ presenter ownership was 1:1, the only
cross-region `ElementName` refs were the finder popup → `SearchBox` pair (same owner),
and only two `StaticResource` keys were shared. WPF namescopes enforce the boundary:
each `XamlReader.Load` root owns its file's namescope, so a presenter handed its region
root physically cannot reach another region's names (the ConfigView → settings-view
seam was the in-repo precedent).

## Shape

- `HomeView.xaml` — 44-line slot-frame shell: `slotActionBar` / `slotStatCards` /
  `slotMachinePane` / `slotDetailArea` (ContentControls, `Focusable=False`
  `IsTabStop=False` so they add no tab stops), plus the body grid + splitter.
- `Home/ActionBar.xaml` — search box + finder popup + mode pill + Run all
  (Finder-owned; popup placement refs stay intra-file).
- `Home/StatCards.xaml` — overview strip (pure `SelectedMachine.Ov*` bindings; its
  Person-mode collapse trigger + bottom margin travel on the region root).
- `Home/MachinePane.xaml` — machines list pane (Home-owned).
- `Home/DetailPane.xaml` — machine detail (Inventory-owned) hosting `slotLens`.
- `Home/LensPane.xaml` — user Lens (binding-only), nested in the detail region.

Composition: `HomePresenter.ComposeRegions` loads each region via `ViewLoader`
(deliberately uncatched — a broken region fails the boot loudly, the rot defense the
old unreachable option views never had). Cross-region lookups (the tour) go through
`HomePresenter.FindHomeElement`, which probes shell + region roots. Converters
(`BoolToVis`) are per-file StaticResource; shared styles (`MachineListItem`, hoisted to
`ModernControls.xaml`) resolve via DynamicResource. DataContext is set once on the
shell root and inherits through the slots.

Also in this change: `Config Options/` → `Settings/`, `*OptionView.xaml` → `*View.xaml`,
`ConfigView.xaml` → `SettingsView.xaml` (class names deliberately untouched), and
`ViewLoader` replacing the three hand-rolled XamlReader blocks.

## Guard rails

`tests/Integration/ViewComposition.Integration.Tests.ps1` (WPF/STA, self-skips
elsewhere): every file under `UI/Views` must load standalone via `ViewLoader` (catches
a missed per-file converter), the shell must expose the four slots (non-focusable), the
tour targets must resolve across region namescopes, and `slotLens` must live in the
detail region only.

## Follow-ups (deliberate non-goals)

- The two inlined SelectableText-derived styles in DetailPane/LensPane (BasedOn can't
  take DynamicResource) — factor if a third copy ever appears.
- `HomePresenter.psm1` (~1,100 lines) is the next split candidate if it keeps growing;
  the region roots now make per-region presenter extraction mechanical.
