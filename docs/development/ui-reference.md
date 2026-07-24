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
| Machine pane header | **Reduction** (+ labelled section) | A `MicroLabel` "MACHINES" titles the pane (every other section has one; "machines" is the app's own word — cf. the "No machines yet" Blank Slate) with `Clear` (removes completed rows) right-aligned, mirroring the detail pane's [title \| buttons] row so the two panes' header buttons line up at the same offset (14). `Clear` is the neutral `ButtonSecondary` — see *Colour hierarchy*. The old All/Online/Offline/Attention **Module Tabs** status filter was removed: it forced a second header row that broke that alignment and earned little at small fleet sizes. The list still orders itself status-grouped (attention first) via a fixed CollectionView sort (`MachineListShaper.StatusRank`); only the interactive filter is gone. |
| Empty machine list | **Blank Slate** | The "No machines yet" guidance with numbered first steps. |
| First-run onboarding | **Guided Tour** (one step at a time, spotlight + callout, always escapable) | Deliberately **not** all-at-once **Coachmarks**, which ui-patterns.com calls "borderline an anti-pattern" for overloading/obstructing. |
| Job progress (scan / apply / inventory / disk) | **Steps Left / Completeness Meter** | One live-progress bar — the glowing gradient bar atop the detail-pane *terminal* (`DetailProgress`) — reflects the selected host's running job: a determinate fill from dcu's step/percent, indeterminate while it's coming, hidden when idle. Single driver: `InventoryPresenter.ShowJobProgress` (called by the inventory/disk flows and, for scan/apply, from `HomePresenter.RefreshCardStatus`). Not on the machine-list card (its "Scanning…" chip already reads busy) and not a separate header bar — one bar, where the live log already draws the eye. The remote dcu log is cleared over the share before tailing so the bar starts fresh, never replaying the prior run's final step. |
| Available Updates card | **Blank Slate** (per-card empty state) | The card shows a "Run a scan on this machine…" hint until it holds results, then the update list. It fills from the last completed scan's report — not only an apply scan: a plain **Scan** populates it on completion (minus the apply prompt), and selecting a machine re-fills it from the report already on disk (a completed/cached scan shows without re-running). Single driver: `HomePresenter.RenderUpdatesFromReport` (called from `ProceedWithApply`, the plain-scan branch of `OnJobCompleted`, and `InventoryPresenter.SelectHost`). Reading is never a re-scan — selection only renders what a prior scan wrote. |
| Identity verdict (on the updates card) | **Progressive Disclosure** | The machine-identity safety check (does the box at the resolved IP answer to the intended name before a destructive apply?) is a compact colour-coded header pill — green `VERIFIED` / amber `UNVERIFIED` / red `WRONG MACHINE` — with the full sentence in its tooltip, instead of a full-width line eating a row on a dense card. State is `HostViewModel.IdentityState` (`Match`/`Mismatch`/`Unknown`), set alongside the rows in `RenderUpdatesFromReport`; the apply confirm dialog still re-checks identity independently (`AbortOnIdentityMismatch`), so shrinking the display costs no safety. |
| Storage folder selection (Clear) | *(no ui-patterns.com pattern — the catalogue has none for multi-select / bulk actions)* | Clearable folder rows in the tree carry a checkbox; the destructive `Clear selected` action lives in the card header. Use the app's themed **`ModernCheckBox`** (violet fill + white check when ticked), never a raw WPF checkbox, so it matches the Arcane look. The checkbox column is `Auto`: protected rows (`FolderDeletionPolicy`) render no checkbox, so the column collapses to zero and their label sits flush against the tree's expander instead of reserving empty space, while clearable rows get a small checkbox indent — the indent itself signals "actionable". |
| Confirmation / alert modal (`DialogWindow`) | **Modal Windows** | One shared modal serves confirm / alert / update-prompt. Minimal chrome per the pattern's escape guidance: an X top-right **and** Esc, **no minimize** (you don't minimise a modal). Left-aligned title (18px bold) over a muted message; list items render as subtle mono cards, not centred plain text. Actions sit bottom-right (secondary then primary). The primary label is **action-specific** ("Clear", not "Confirm") — the pattern's "match the button text to the title" — and turns **red (`ButtonDestructive`) for irreversible actions** (`DialogViewModel.IsDestructive`), keeping colour tied to meaning. MVP, not MVVM: `DialogPresenter.ApplyPrimaryStyle` picks the primary button's style in code rather than a XAML trigger bound to VM state. |

## Colour hierarchy (button variants)

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
  follow this: neutral grey, subordinate to the row's `Run`.

## Working notes distilled from the patterns

- **Guided Tour**: one idea per step, keep it short (people hold ~3–4 things at once), always
  allow escape/skip, self-paced. Offer Skip once; Esc exits throughout.
- **Autocomplete**: order by relevance, group into categories, highlight the match, Esc to dismiss.
- Match the treatment to the task; don't over-design utilitarian surfaces.
