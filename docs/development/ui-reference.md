---
title: UI reference
description: The canonical UI pattern source for DONUT and the patterns applied so far, plus the Arcane visual language.
---

**Canonical source for all UI/UX work on DONUT: <https://ui-patterns.com/patterns>.**

Before designing or changing any UI, consult ui-patterns.com to find the established
pattern for the problem, follow its guidance, and prefer it over an ad-hoc solution. When a
pattern warns against something (e.g. it calls an approach an anti-pattern), heed that.

This complements — it does not replace — DONUT's visual language: the Arcane-modelled
neutral + violet-600 palette and shadcn button variants defined in `src/UI/Styles`
(`UIColors.xaml`, `ButtonStyles.xaml`, `ModernControls.xaml`, `Tokens.xaml`). Patterns decide
*behaviour and structure*; the Arcane tokens decide *look*.

## Patterns applied so far

| Area | Pattern | Notes |
|------|---------|-------|
| Home search dropdown | **Autocomplete** (relevance-ordered, categorized suggestions) | Added an explicit "Add ‹typed› as a machine" row instead of inline ghost-text (inline typeahead isn't covered by the pattern and is fragile for async AD results). |
| Machine pane header | **Reduction** (+ labelled section) | A "Machines" pane title (`TextPaneTitle`, 18px bold — the equal-weight partner of the detail pane's hostname title) with `Clear` (removes completed rows) right-aligned, mirroring the detail pane's [title \| buttons] row so the two panes' header buttons line up at the same offset (14). `Clear` is the neutral `ButtonSecondary` — see *Colour hierarchy*; the settings keybind rows' smaller field-level `Clear` is `ButtonGhost` (a lower tier for a lower-stakes, in-form action). The old All/Online/Offline/Attention **Module Tabs** status filter was removed: it forced a second header row that broke that alignment and earned little at small fleet sizes. The list still orders itself status-grouped (attention first) via a fixed CollectionView sort (`MachineListShaper.StatusRank`); only the interactive filter is gone. |
| Empty machine list | **Blank Slate** | The "No machines yet" guidance with numbered first steps. |
| First-run onboarding | **Guided Tour** (one step at a time, spotlight + callout, always escapable) | Deliberately **not** all-at-once **Coachmarks**, which ui-patterns.com calls "borderline an anti-pattern" for overloading/obstructing. |
| Job progress (scan / apply / inventory / disk) | **Steps Left / Completeness Meter** | One live-progress bar — the glowing gradient bar atop the detail-pane *terminal* (`DetailProgress`) — reflects the selected host's running job: a determinate fill from dcu's step/percent, indeterminate while it's coming, hidden when idle. Single driver: `InventoryPresenter.ShowJobProgress` (called by the inventory/disk flows and, for scan/apply, from `HomePresenter.RefreshCardStatus`). Not on the machine-list card (its "Scanning…" chip already reads busy) and not a separate header bar — one bar, where the live log already draws the eye. The remote dcu log is cleared over the share before tailing so the bar starts fresh, never replaying the prior run's final step. An apply's **download** phase drives a determinate percent (`DcuProgress.ParsePercent`), but the **install** phase reports no sub-percentage (a single update reports nothing), so `DcuProgress.IsInstalling` flips the bar to indeterminate there — it keeps animating instead of freezing at the download's 100%. |
| Available Updates card | **Blank Slate** (per-card empty state) | The card shows a "Run a scan on this machine…" hint until it holds results, then the update list. It fills from the last completed scan's report — not only an apply scan: a plain **Scan** populates it on completion (minus the apply prompt), and selecting a machine re-fills it from the report already on disk (a completed/cached scan shows without re-running). Single driver: `HomePresenter.RenderUpdatesFromReport` (called from `ProceedWithApply`, the plain-scan branch of `OnJobCompleted`, and `InventoryPresenter.SelectHost`). Reading is never a re-scan — selection only renders what a prior scan wrote. |
| Identity verdict (on the updates card) | **Progressive Disclosure** | The machine-identity safety check (does the box at the resolved IP answer to the intended name before a destructive apply?) is a compact colour-coded header pill — green `VERIFIED` / amber `UNVERIFIED` / red `WRONG MACHINE` — with the full sentence in its tooltip, instead of a full-width line eating a row on a dense card. State is `HostViewModel.IdentityState` (`Match`/`Mismatch`/`Unknown`), set alongside the rows in `RenderUpdatesFromReport`; the apply confirm dialog still re-checks identity independently (`AbortOnIdentityMismatch`), so shrinking the display costs no safety. |
| Storage folder selection (Clear) | *(no ui-patterns.com pattern — the catalogue has none for multi-select / bulk actions)* | Clearable folder rows in the tree carry a checkbox; the destructive `Clear selected` action lives in the card header. Use the app's themed **`ModernCheckBox`** (violet fill + white check when ticked), never a raw WPF checkbox, so it matches the Arcane look. The checkbox column is `Auto`: protected rows (`FolderDeletionPolicy`) render no checkbox, so the column collapses to zero and their label sits flush against the tree's expander instead of reserving empty space, while clearable rows get a small checkbox indent — the indent itself signals "actionable". Checkboxes are **tri-state / hierarchical** (Windows "features" style): `FolderNodeViewModel` is an `ObservableObject` whose `SetChecked` cascades to deletable descendants and rolls a parent up to checked / unchecked / indeterminate (`ModernCheckBox` shows a dash for the null state). The presenter only relays the click (`OnFolderCheckToggled`, guarded against the cascade's own routed Checked/Unchecked echo); `CollectSelected` then clears only fully-checked subtrees, so an unchecked child is never touched. |
| Debug-logging toggle (Settings → General → DIAGNOSTICS) | **Good Defaults** | Verbose `[DEBUG]` logging defaults **off** — the pattern's "pre-select what most users would choose" (daily use wants a readable log; failures still log at WARN/ERROR). The override is as effortless as the default (the pattern's other half): one `ModernToggleSwitch` flip applies live — no restart, workers included — or `Start-Donut -DebugLog` for a session-only force-on that never touches the saved setting. The catalogue has **no** settings-organization pattern (interaction-focused), so the row follows the app's own settings convention: its own `SettingsSectionLabel` card ("DIAGNOSTICS"), toggle + label row identical to STARTUP & TRAY. |
| Confirmation / alert modal (`DialogWindow`) | **Modal Windows** | One shared modal serves confirm / alert / update-prompt. Minimal chrome per the pattern's escape guidance: an X top-right **and** Esc, **no minimize** (you don't minimise a modal). Left-aligned title (`TextPaneTitle`) over a muted message; list items render as subtle mono cards, not centred plain text. Actions sit bottom-right (secondary then primary). The primary label is **action-specific** ("Clear" / "Apply" / "Unlock", never a generic "Confirm") — the pattern's "match the button text to the title" — and every call site passes the 5-arg `ShowConfirmation` overload. Buttons use the app's **tint** variants, not the heavier solid fills, to match the arcane action buttons (Run/Add): the primary is `ButtonTintPrimary`, or `ButtonTintDestructive` (red tint) for irreversible actions — folder clears **and both apply-updates confirms** (BIOS/firmware installs don't roll back). MVVM (matching the app): the presenter *builds* the VM, resolving the primary button's Style onto `DialogViewModel.PrimaryStyle` (the same presenter-resolves / VM-holds / view-binds pattern as `HostViewModel.ChipBackground`), and the view **binds** `Button.Style="{Binding PrimaryStyle}"` — no `FindName` style-poking. The presenter still does the imperative shell work (load window, `ShowDialog`, wire X/Esc/drag), which the architecture assigns to presenters even under MVVM. |
| Truncatable text (hostnames, paths, names, versions) | **Progressive Disclosure** (hover reveals the rest) | Single-line variable-length text either trims with `TextTrimming="CharacterEllipsis"` (TextBlocks) or clips (the `SelectableText` TextBoxes — WPF TextBoxes have no trimming), and in both cases carries a `ToolTip` bound to the same value so the full text is one hover away. Copy-valuable values (hostname, service tag, person fields) stay `SelectableText` — selectability is why they are TextBoxes at all. |
| QR overlay (BitLocker recovery key) | *(no ui-patterns entry — hardware constraint decides)* | The QR renders **inverted by choice**: violet-300 modules (`QrModuleColor`) on a transparent background, blending straight into the dark card (~10:1 contrast) with the 12px inset as the quiet zone — no light plate. **Field-gated on the hardware scanner**: the BitLocker workflow uses a dedicated laser/imager scanner, and older 2D imagers often can't decode inverse QR — if it fails the scan test, revert to dark-on-light (recipe in `UIColors.xaml` at the `QrModule*` keys) rather than tweaking colours. Phone cameras read either. |
| Type/spacing tokens (`Tokens.xaml`, `StatusStyles.xaml`) | *(visual language, not a ui-patterns entry)* | Text scale: `TextPaneTitle` (18/Bold — pane, overlay, and dialog titles) > `TextTitle` (16) > `TextSubtitle` (14) > `TextBody` (13) > `TextBodyMuted` (12.5) > `TextMono` (12); stat tiles use `StatValue` + `MicroLabel`. Status badges are the 5-colour `Badge*` family (one recipe: rounded 8.4, tinted fill, 11px semibold text) — the reboot warning uses `BadgeAmber`, never a hand-rolled amber row. Radii: 10 = cards (incl. terminal + device cards), 8.4 = controls/chips/badges, 7 = dropdown rows, 6 = small chips. Glyphs pin `FontSymbol` so they never render as tofu. New UI adopts these tokens instead of restating font/radius values inline. |

## Colour hierarchy (button variants)

The status accents (row dot/chip/progress) are defined once in `UIColors.xaml`;
`HomePresenter.SeedRowPalette` resolves them at startup and hands `HostViewModel` frozen
brushes (10%/30% alpha tints derived there) — no hexes live outside `src/UI/Styles`.

ui-patterns.com has **no** dedicated pattern for button colour / CTA prominence (its catalogue
is interaction-focused); the nearest principles it endorses are **Reduction** (simplify, cut
attention load) and **Tunnelling** (direct focus). For *look*, the canonical source is DONUT's
shadcn button variants in `src/UI/Styles/ButtonStyles.xaml`. The rule we follow:

- **Reserve saturated colour for meaning or the one primary action.** Status/urgency badges
  (amber `UNVERIFIED`, sky `Recommended`, green `Completed`) and the primary CTA earn colour
  because it *encodes* something.
- **Decorative tints are the anti-pattern.** A `ButtonTint*` fill whose colour signals nothing
  (e.g. "Storage scan" in indigo, "Refresh info" in cyan) just competes with the meaningful
  colour nearby. Secondary/utility actions use the neutral **`ButtonSecondary`** (grey) — or
  `ButtonOutline`/`ButtonGhost` — so they read as subordinate. The detail-pane header buttons
  follow this: neutral grey, subordinate to the row's `Run`. Same rule on the Lens device
  card: `Add` (the row's action) is the one tint; `Reveal key`/`QR` are grey utilities.
- **One tint per row, and it marks the row's primary action.** `Run` = `ButtonTintSuccess`,
  `Add` = `ButtonTintPrimary`, `Unlock` (a locked search row's one action) =
  `ButtonTintPrimary`, `Clear selected` = `ButtonTintDestructive`. `ButtonOutline` is
  reserved for low-emphasis navigation (the tour's Back). The solid `ButtonPrimary`/
  `ButtonDestructive` remain the reserved main-CTA tier — currently unused by design.

## Working notes distilled from the patterns

- **Guided Tour**: one idea per step, keep it short (people hold ~3–4 things at once), always
  allow escape/skip, self-paced. Offer Skip once; Esc exits throughout.
- **Autocomplete**: order by relevance, group into categories, Esc to dismiss. (The pattern
  also suggests highlighting the matched substring; not implemented — revisit if rows get
  hard to scan at real fleet sizes.)
- Match the treatment to the task; don't over-design utilitarian surfaces.
- **Overlay Esc discipline**: an overlay's Esc `KeyBinding` only fires if focus is inside it —
  every overlay (settings, QR, tour) focuses its card/callout on show.
