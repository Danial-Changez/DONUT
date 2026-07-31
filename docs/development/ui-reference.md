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

**Reference stack, in priority order:**

1. **ui-patterns.com** — behaviour and structure (which pattern, when).
2. **Arcane / shadcn tokens** (`src/UI/Styles`) — look: palette, radii, type tiers, button
   variants. The primary styling authority; the rest of the UI follows it.
3. **Fluent 2** (<https://fluent2.microsoft.design>) — *secondary*, for what the first two
   are silent on: spacing rhythm, label/value hierarchy, dialog anatomy, window-chrome
   conventions, hit-target sizes. When composing any new surface, sanity-check it against
   Fluent's metrics *before* review — breathing room and hierarchy misses should be caught
   here, not by a human looking at a screenshot.

## Patterns applied so far

| Area | Pattern | Notes |
|------|---------|-------|
| Home search dropdown | **Autocomplete** (relevance-ordered, categorized suggestions) | Added an explicit "Add ‹typed› as a machine" row instead of inline ghost-text (inline typeahead isn't covered by the pattern and is fragile for async AD results). |
| Machine pane header | **Reduction** (+ labelled section) | A "Machines" pane title (`TextPaneTitle`, 18px bold — the equal-weight partner of the detail pane's hostname title) with `Clear` (removes completed rows) right-aligned, mirroring the detail pane's [title \| buttons] row so the two panes' header buttons line up at the same offset (14). `Clear` is the neutral `ButtonSecondary` — see *Colour hierarchy*; the settings keybind rows' smaller field-level `Clear` is `ButtonGhost` (a lower tier for a lower-stakes, in-form action). The old All/Online/Offline/Attention **Module Tabs** status filter was removed: it forced a second header row that broke that alignment and earned little at small fleet sizes. The list still orders itself status-grouped (attention first) via a fixed CollectionView sort (`MachineListShaper.StatusRank`); only the interactive filter is gone. |
| Empty machine list | **Blank Slate** | The "No machines yet" guidance with numbered first steps. |
| First-run onboarding | **Guided Tour** (one step at a time, spotlight + callout, always escapable) | Deliberately **not** all-at-once **Coachmarks**, which ui-patterns.com calls "borderline an anti-pattern" for overloading/obstructing. |
| Job progress (scan / apply / inventory / disk) | **Steps Left / Completeness Meter** | One live-progress bar — the glowing gradient bar atop the detail-pane *terminal* (`DetailProgress`) — reflects the selected host's running job: a determinate fill from dcu's step/percent, indeterminate while it's coming, hidden when idle. Single driver: `InventoryPresenter.ShowJobProgress` (called by the inventory/disk flows and, for scan/apply, from `HomePresenter.RefreshCardStatus`). Not on the machine-list card (its "Scanning…" chip already reads busy) and not a separate header bar — one bar, where the live log already draws the eye. The remote dcu log is cleared over the share before tailing so the bar starts fresh, never replaying the prior run's final step. An apply's **download** phase drives a determinate percent (`DcuProgress.ParsePercent`), but the **install** phase reports no sub-percentage (a single update reports nothing), so `DcuProgress.IsInstalling` flips the bar to indeterminate there — it keeps animating instead of freezing at the download's 100%. |
| Terminal log lines (detail pane) | *(no ui-patterns.com pattern — severity colouring is a console convention)* | Every terminal line is a typed `LogLine` (severity + normalized dim `HH:mm:ss` stamp + text); dcu-tailed lines have their full date-time prefix re-stamped down so the terminal shows one uniform stamp (full fidelity stays in the log files). Severity maps to the existing palette keys — `[Error]` `AccentRed`, `[Warn]` `AccentYellow`, success lines `AccentGreen`, default `TerminalText`, stamps `BodyTextTertiary` — and Error/Warn also carry their text tag, so colour is **never the only carrier** of meaning (the *Reserve saturated colour for meaning* rule below). The renderer is a chromeless virtualized `ListBox` (`lstDetailLog`, Recycling mode) so a 2000-line ring buffer realizes only the visible rows; per-line rendering costs cross-line drag-selection, which the terminal's `Copy` ghost button (`InventoryPresenter.CopyHostLog`) replaces. Severity is decided at the source (`AsyncJob.DrainStream` keeps the PowerShell stream a record arrived on; dcu wording only ever upgrades Info to Warn — the return code stays the authority on failure). |
| Available Updates card | **Blank Slate** (per-card empty state) | The card shows a "Run a scan on this machine…" hint until it holds results, then the update list. It fills from the last completed scan's report — not only an apply scan: a plain **Scan** populates it on completion (minus the apply prompt), and selecting a machine re-fills it from the report already on disk (a completed/cached scan shows without re-running). Single driver: `HomePresenter.RenderUpdatesFromReport` (called from `ProceedWithApply`, the plain-scan branch of `OnJobCompleted`, and `InventoryPresenter.SelectHost`). Reading is never a re-scan — selection only renders what a prior scan wrote. |
| Identity verdict (on the updates card) | **Progressive Disclosure** | The machine-identity safety check (does the box at the resolved IP answer to the intended name before a destructive apply?) is a compact colour-coded header pill — green `VERIFIED` / amber `UNVERIFIED` / red `WRONG MACHINE` — with the full sentence in its tooltip, instead of a full-width line eating a row on a dense card. State is `HostViewModel.IdentityState` (`Match`/`Mismatch`/`Unknown`), set alongside the rows in `RenderUpdatesFromReport`; the apply confirm dialog still re-checks identity independently (`AbortOnIdentityMismatch`), so shrinking the display costs no safety. |
| Storage folder selection (Clear) | *(no ui-patterns.com pattern — the catalogue has none for multi-select / bulk actions)* | Clearable folder rows in the tree carry a checkbox; the destructive `Clear selected` action lives in the card header. Use the app's themed **`ModernCheckBox`** (violet fill + white check when ticked), never a raw WPF checkbox, so it matches the Arcane look. The checkbox column is `Auto`: protected rows (`FolderDeletionPolicy`) render no checkbox, so the column collapses to zero and their label sits flush against the tree's expander instead of reserving empty space, while clearable rows get a small checkbox indent — the indent itself signals "actionable". Checkboxes are **tri-state / hierarchical** (Windows "features" style): `FolderNodeViewModel` is an `ObservableObject` whose `SetChecked` cascades to deletable descendants and rolls a parent up to checked / unchecked / indeterminate (`ModernCheckBox` shows a dash for the null state). The presenter only relays the click (`OnFolderCheckToggled`, guarded against the cascade's own routed Checked/Unchecked echo); `CollectSelected` then clears only fully-checked subtrees, so an unchecked child is never touched. |
| Debug-logging toggle (Settings → General → DIAGNOSTICS) | **Good Defaults** | Verbose `[DEBUG]` logging defaults **off** — the pattern's "pre-select what most users would choose" (daily use wants a readable log; failures still log at WARN/ERROR). The override is as effortless as the default (the pattern's other half): one `ModernToggleSwitch` flip applies live — no restart, workers included — or `Start-Donut -DebugLog` for a session-only force-on that never touches the saved setting. The catalogue has **no** settings-organization pattern (interaction-focused), so the row follows the app's own settings convention: its own `SettingsSectionLabel` card ("DIAGNOSTICS"), toggle + label row identical to STARTUP & TRAY. |
| Confirmation / alert modal (`DialogWindow`) | **Modal Windows** | One shared modal serves confirm / alert / update-prompt. Minimal chrome per the pattern's escape guidance: an X top-right **and** Esc, **no minimize** (you don't minimise a modal). Left-aligned title (`TextPaneTitle`) over a muted message; list items render as subtle mono cards, not centred plain text. Actions sit bottom-right (secondary then primary). The primary label is **action-specific** ("Clear" / "Apply" / "Unlock", never a generic "Confirm") — the pattern's "match the button text to the title" — and every call site passes the 5-arg `ShowConfirmation` overload. Buttons use the app's **tint** variants, not the heavier solid fills, to match the arcane action buttons (Run/Add): the primary is `ButtonTintPrimary`, or `ButtonTintDestructive` (red tint) for irreversible actions — folder clears **and both apply-updates confirms** (BIOS/firmware installs don't roll back). MVVM (matching the app): the presenter *builds* the VM, resolving the primary button's Style onto `DialogViewModel.PrimaryStyle` (the same presenter-resolves / VM-holds / view-binds pattern as `HostViewModel.ChipBackground`), and the view **binds** `Button.Style="{Binding PrimaryStyle}"` — no `FindName` style-poking. The presenter still does the imperative shell work (load window, `ShowDialog`, wire X/Esc/drag), which the architecture assigns to presenters even under MVVM. |
| Truncatable text (hostnames, paths, names, versions) | **Progressive Disclosure** (hover reveals the rest) | Single-line variable-length text either trims with `TextTrimming="CharacterEllipsis"` (TextBlocks) or clips (the `SelectableText` TextBoxes — WPF TextBoxes have no trimming), and in both cases carries a `ToolTip` bound to the same value so the full text is one hover away. Copy-valuable values (hostname, service tag, person fields) stay `SelectableText` — selectability is why they are TextBoxes at all. |
| Title bar (logo + window controls) | **Reduction** | The 48px branding row is gone: the wordmark sits left in a single 36px control bar (LoginWindow's DockPanel idiom - buttons dock right in an RTL StackPanel, the logo is the LTR fill child). The logo's left inset matches the content margin (25; Login's matches its 16) so it sits on the same column as the search bar instead of hugging the corner, and at 20px tall it keeps visible air above and below in the 36px bar. The logo is passive chrome (`IsHitTestVisible="False"`), so the whole bar stays the DragMove surface. At 36px the title-bar close is literally 50x36 - the footprint the overlay/dialog closes already mirror. |
| Temp-password reset overlay | **Modal Windows** chrome + **Input Prompt** + **Input Feedback** + **Good Defaults** + **Progressive Disclosure** | A finder user row's grey `Reset…` (`ButtonSecondary` - one tint per row; Unlock keeps it) opens a settings/QR-idiom overlay card on the standard modal anatomy (fixed header / body / two-CTA footer): a **48px header row** where the X keeps its flush 50x36 corner pad pinned Top (`controlButtonCardClose` - the controlButton pad with its top-right rounded to the card radius, so overlay closes match the title-bar/dialog treatment instead of floating inside the gutter) and the **title centers beside it** with clear top air, **naming the target** ("Reset password *(Name)*", name in the tertiary tone, ellipsis + tooltip). Body: the UPN and SAM as **two side-by-side tiles on the shared `Card` recipe** (they hold data, so they wear the same scheme as the home stat cards - `SurfaceMuted` is reserved for the dialog's transient list rows), each the person-fields pairing (MicroLabel grey over a brighter `TitleTextPrimary` selectable mono value; label and value differ in colour, not just size; the home domain stays off the card - the worker still targets it, the UPN already implies it), then the watermarked password field (mono; ModernTextBox `Tag='error'` red border + warning toast under 8 chars; the watermark clears on **focus**, not just on text - as a sibling overlay it can't share the caret's layout path, so the caret would otherwise sit inside the ghost text) with **Copy/QR icon buttons** (Font Awesome free `Copy`/`QrCode` geometries in Icons.xaml) attached beside it - **disabled until a password exists** (Progressive Disclosure; the gate wraps them in a `ContentControl` DataTrigger because the runtime DynamicResource button styles can't take `BasedOn`; `ToolTipService.ShowOnDisabled` keeps the hint alive), then the pre-checked change-at-logon checkbox (Good Defaults). Footer pairs the flow: **Generate left**, the action-specific `ButtonTintDestructive` "Reset password" right (discarding the current password is irreversible); no Close button - X/Esc/backdrop already close, per the modal chrome rule. QR pops the shared `qrOverlay`, which sits after `resetOverlay` in z-order and hands focus back on close per the Esc discipline. 24px content gutters, footer sizes 36px/MinWidth 96. Success toasts and keeps the card open (the operator still hands the password over); closing wipes the secret. |
| QR overlay (BitLocker recovery key) | *(no ui-patterns entry — hardware constraint decides)* | The QR renders **inverted by choice**: violet-300 modules (`QrModuleColor`) on a transparent background, blending straight into the dark card (~10:1 contrast) with the 12px inset as the quiet zone — no light plate. **Field-gated on the hardware scanner**: the BitLocker workflow uses a dedicated laser/imager scanner, and older 2D imagers often can't decode inverse QR — if it fails the scan test, revert to dark-on-light (recipe in `UIColors.xaml` at the `QrModule*` keys) rather than tweaking colours. Phone cameras read either. |
| Lens device card (model + service tag) | *(no ui-patterns.com entry - the catalogue's nearest matches govern data entry, not display)* | The card exists to tell a person's three similar laptops apart, and it used to render four facts past the name (OS, last logon, model, service tag) as two visually identical dim mono lines, the second a run-on `Model - SN Serial`. The catalogue has nothing for this: **Structured Format** is about *entering* data to a fixed shape, and **Chunking** explicitly excludes information that must be "searched, scanned, or analyzed", which is exactly this task. So the call falls to tier 2, the app's own recipe. **Two lines, three tiers, one sub-line:** `Model  ·  Tag <service tag>  ·  seen <when>`, with model in `TitleTextPrimary` because it is what actually separates one machine from another, the tag `FontMono` (transcribed off a sticker, so 0/O and 1/I must stay apart) and last-seen `FontSans`, both tertiary. Hierarchy comes from colour and font, not from a label row. The word is **Tag**, matching the MACHINE stat tile's `Tag <service tag>` sub-line rather than inventing a second name for one fact (the old card said `SN`). **The OS moved to the row tooltip** alongside the manufacturer: a person's machines nearly always share one OS, so the field cost the most prominent sub-line to say nothing, while still deciding a Windows 10 holdout - which is the **Progressive Disclosure** treatment this table already applies to truncatable text. A labelled two-column `MODEL`/`TAG` grid (the person-fields pairing) was built first and rejected: it repeats two labels on every card, and a column header block over separately-bordered cards cannot own its columns, besides promising a **Sort By Column** interaction the fixed last-seen ordering does not offer. Each value carries its own trailing separator inside a collapsing `StackPanel`, so a device SCCM cannot serve leaves no orphaned dot; the row's buttons sit `VerticalAlignment="Top"` so `Add` stays level with the device name. |
| Elevation state (control bar) | **Progressive Disclosure** + **Status Feedback** | A de-elevated DONUT wears a standing amber `LIMITED` badge in the 36px control bar, immediately right of the wordmark, with the full sentence and the remedy in its tooltip. Same treatment as the updates card's identity verdict: a compact colour-coded pill rather than a line of prose, detail one hover away. It uses the `BadgeAmber` / `BadgeAmberText` recipe, never a hand-rolled amber pill. **A toast was not enough on its own.** De-elevation lasts the whole session, and a transient notification answers "what just happened", not "what am I in right now" - the toast still fires once on an autostart to explain *why* this launch is limited, but the badge is what stays available for reference. It is driven by `ElevationContext::IsElevated()`, not by `runAsAdmin` or the autostart flag: the setting records what was wanted, the badge has to report what the process actually got, so it stays correct after a declined prompt or a manual de-elevated launch. The wordmark keeps `IsHitTestVisible="False"` so the bar stays the DragMove surface; the badge is hit-testable because a tooltip needs hover, which costs drag on those ~70px. |
| Surfacing from the tray | **Modal Windows** (one at a time) | Restoring from the tray runs the deferred sign-in / update prompt **before** `Window.Show()`, the order a cold start already used in `DonutApp.ps1`. Showing first put the main window and the login modal on screen together, so the app looked like it had opened twice and anything the toast said was lost behind the modal. A cancelled sign-in still shows the main window, matching the cold path. |
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
- **Chrome is neutral.** Window and popup borders are the `PanelBorder` hairline — the old
  violet gradient ramp was ornament (Reduction: it competed with status colour and marked
  nothing). Popup close buttons follow the *Popup chrome contract* below.

## Popup chrome contract

Every popup — the modal `DialogWindow` (apply-updates / disk-clear confirms, alerts, the
update prompt) and the shell overlay cards (settings, QR, reset) — shares one chrome:

- **X, always, flush in the top-right corner** with the title-bar close's 50x36 pad:
  `controlButton` (square pad) on square windows, `controlButtonCardClose` (top-right
  corner rounded to the card radius) on radius-10 cards. Never inset into the gutter.
- **Corner radius has two tiers:** top-level windows are `CornerRadius="0"` (Win11's DWM
  rounds the outer frame); in-window overlay cards are `RadiusCard` (10).
- **Header is one 48px row** (`MinHeight` where a dynamic caption may wrap, e.g. the QR
  card): the title sits beside the X, vertically centered with clear top air, `TextPaneTitle`
  at a 24px left inset, single-line with ellipsis + tooltip when the text is dynamic; the X
  pins `Top`. On `DialogWindow` this row doubles as the drag region.
- **The header may also carry that popup's page switcher**, right-aligned and clear of the
  X's 56px lane. Settings puts its General/Scan/Apply segments there rather than at the top
  of the scrolling body: nav that scrolls away is nav you cannot reach from the bottom of a
  long form, and the row had the space already. The title keeps its 24px inset and the X
  keeps its flush corner pad, so the contract above is unchanged for popups without pages.
- **Content gutters are 24px** inside every popup.
- **Footers hold decisions only** — an action-named primary and a verdict secondary
  (`Cancel` / `Later`; `OK` alone on alerts). A dismiss-only "Close" button is banned:
  X + Esc (+ backdrop click on overlays) already dismiss.
- Esc/backdrop behaviour per the *Overlay Esc discipline* note; the guided tour is the
  documented exception (no X, inert backdrop, Skip/Esc exit).
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
- **Spacing & hierarchy defaults** (apply automatically, per the Fluent 2 layer):
  a surface's title never hugs its top edge — on overlay cards make the header row
  taller than the close pad (48px row, X pinned Top with its flush 50x36 corner pad,
  title vertically centered) so title and X share a row *and* the title gets top air;
  a label and its value must differ in **colour, not just size** (MicroLabel grey over
  a `TitleTextPrimary` value — the person-fields recipe); data-holding tiles wear the
  shared `Card` recipe, `SurfaceMuted` is only for a dialog's transient list rows;
  brand/chrome elements align to the content column (the logo shares contentMain's
  25px inset), and anything inside a fixed-height bar keeps visible air above and
  below (the 20px wordmark in the 36px bar).
- **Overlay Esc discipline**: an overlay's Esc `KeyBinding` only fires if focus is inside it —
  every overlay (settings, QR, tour) focuses its card/callout on show.
