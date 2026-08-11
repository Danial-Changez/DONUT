---
title: UI reference
description: The canonical UI pattern source for DONUT, the rules applied so far, and the Arcane visual language.
---

**Canonical source for all UI/UX work on DONUT: <https://ui-patterns.com/patterns>.**
Find the established pattern before designing, follow its guidance, and heed its
anti-pattern warnings. Rationale for the calls below lives in
[Design decisions](./decisions.md#ui-decisions).

**Reference stack, in priority order:**

1. **ui-patterns.com** — behaviour and structure (which pattern, when).
2. **Arcane / shadcn tokens** (`src/UI/Styles`) — look: palette, radii, type tiers,
   button variants. The primary styling authority.
3. **Fluent 2** — for what the first two are silent on: spacing rhythm,
   label/value hierarchy, dialog anatomy, hit-target sizes. Sanity-check new
   surfaces against Fluent's metrics before review.

## Writing UI text

Two capitalization schemes, chosen by what the text *is*:

| Scheme | Applies to | Example |
|---|---|---|
| **Title Case** | Buttons, menu items, headings, pane and section titles, tab and segment names, setting labels, dialog titles | `Clear Selected`, `Run All`, `Reveal Key`, `Close to Tray` |
| **Sentence case** | Tooltips, hint and helper text, blank-slate copy, dialog message bodies, toasts | `Clears the folder contents and keeps the folder.` |

Articles and short prepositions (of, to, in, with, for, as) stay lowercase in
Title Case unless they lead or close the label, so `Start with Windows` is already
correct. Proper nouns and acronyms keep their own casing (DONUT, BitLocker, SCCM,
BIOS, DCU, QR, AD). Deliberate all-caps style tokens — a `SettingsSectionLabel`
like `DIAGNOSTICS`, or a status badge — are a visual tier rather than prose, and
are left alone.

**Prefer the shortest label that stays unambiguous.** One word beats two when the
meaning survives, but never at the cost of a collision with another control
visible at the same time.

### Tooltips

A tooltip has to earn its place:

- **Delete it** when it restates the control's own visible label. A button
  labelled `Unlock` carries no `Unlock this account` tooltip.
- **Keep it** on an icon-only control, where it is the only affordance, and keep
  it to a few words.
- **Keep it** when it says something the visible text does not: the full sentence
  behind a status pill, the OS on a Lens device row, or why a disabled control is
  gated (`ToolTipService.ShowOnDisabled`).
- **Keep it** when bound to the same value as truncatable text. Those reveal
  clipped content, and WPF cannot gate them
  ([why](./decisions.md#tooltips-on-untrimmed-text-stay-unconditional)).

Whatever survives is short. Prose that needs a sentence belongs in the surface
itself, not in a tooltip.

## Rules applied so far

| Surface | Pattern | The rule |
|---|---|---|
| Search dropdown | Autocomplete | Enter acts on real rows only — pre-select is the top-ranked computer, else the top user; it can never fabricate a machine. Picking a computer *is* the add. The one non-row Enter is a pasted multi-token list. Sections cap at `MaxDropdownRows` (15) with a non-pickable `+N MORE` header; the list pixel-scrolls; popup closes on Esc, focus loss, or deactivation. |
| Machine pane header | Reduction | Pane title + right-aligned `Clear` (`ButtonSecondary`), mirroring the detail pane's header offsets. Each card carries its own ✕ (`fieldClearButton` recipe — one clear-X affordance app-wide); a running host toasts and stays. No filter tabs; the list keeps its fixed status-grouped sort (`MachineListShaper.StatusRank`, attention first). |
| Empty machine list | Blank Slate | "No machines yet" with numbered first steps. |
| Onboarding | Guided Tour | One step at a time, spotlight + callout, always escapable. Not all-at-once coachmarks. |
| Job progress | Completeness Meter | One live bar (`DetailProgress`, atop the terminal), single driver `InventoryPresenter.ShowJobProgress`. Determinate from dcu's percent; `DcuProgress.IsInstalling` flips it indeterminate (installs report no sub-percentage). The remote dcu log is cleared before tailing so the bar never replays the prior run. |
| Terminal log | *(console convention)* | Every line is a typed `LogLine`: severity colour **plus** an `[Error]`/`[Warn]` text tag — colour is never the only carrier. Uniform dim `HH:mm:ss` stamps; chromeless virtualized ListBox (Recycling); `Copy` replaces drag-selection. Severity is decided at the source (`AsyncJob.DrainStream`); the return code stays the authority on failure. |
| Available updates card | Blank Slate | Hint until results; fills from the last completed scan's report via one driver (`HomePresenter.RenderUpdatesFromReport`). Selection re-renders what a prior scan wrote — reading is never a re-scan. |
| Identity verdict | Progressive Disclosure | Compact colour pill (`VERIFIED`/`UNVERIFIED`/`WRONG MACHINE`) with the full sentence in its tooltip; the apply confirm re-checks identity independently, so the compact display costs no safety. |
| Storage folder selection | *(no catalogue entry)* | Themed `ModernCheckBox` only. Protected rows render no checkbox (the `Auto` column collapses — the indent itself signals actionable). Cascade is downward only; unchecking a child releases any checked ancestor. `CollectSelected` clears only explicitly checked subtrees. |
| Debug toggle | Good Defaults | Verbose logging defaults off; the override is one live toggle flip (workers included) or `Start-Donut -DebugLog` for a session-only force-on. |
| Dialogs (`DialogWindow`) | Modal Windows | One shared modal for confirm/alert/update. X + Esc, no minimize. Action-specific primary label ("Clear"/"Apply", never "Confirm"), 5-arg `ShowConfirmation` at every call site. Tint variants, not solid fills; `ButtonTintDestructive` for irreversible actions (folder clears, both apply confirms). The presenter builds the VM (resolving `PrimaryStyle`); the view binds it — no `FindName` style-poking. |
| Truncatable text | Progressive Disclosure | Ellipsis (TextBlocks) or clip (`SelectableText` TextBoxes) + a tooltip bound to the same value. Copy-valuable values stay `SelectableText`. Same-value tooltips stay unconditional — WPF cannot gate them ([why](./decisions.md#tooltips-on-untrimmed-text-stay-unconditional)). A tooltip that adds nothing to a labelled button is banned. |
| Title bar | Reduction | One 36px control bar: wordmark left at the content column's 25px inset, passive (`IsHitTestVisible=False`) so the bar stays the DragMove surface; window controls dock right. |
| Temp-password overlay | Modal + Input Prompt/Feedback + Good Defaults | Standard overlay anatomy (48px header, title names the target, flush corner X). UPN/SAM as two `Card` tiles (person-fields pairing); password field watermarked mono with `Tag='error'` feedback under 8 chars (watermark clears on **focus**); Copy/QR disabled until a password exists; change-at-logon pre-checked. Generate left, `ButtonTintDestructive` "Reset Password" right; no Close button. Success keeps the card open; closing wipes the secret. |
| QR overlay (BitLocker) | *(hardware constraint)* | Inverted by choice: violet modules on the dark card, 12px quiet zone. Field-gated on the hardware scanner — if it fails the scan test, revert to dark-on-light (`QrModule*` keys), don't tweak colours. |
| Lens person pane | Card layout | The person's facts (EMAIL/MANAGER/SAM/OFFICE) sit in a 2×2 grid of dense `Card` tiles (`Padding="12,8"`, 6/6 gutters) — the temp-password overlay's person-fields pairing, `MicroLabel` over a `TitleTextPrimary` value, identity strings (email, SAM) in mono. The DEVICES/SOFTWARE header toggles the list slot; software rows wear the device-row card and column anatomy, name over collection, the package program as a right-aligned `BadgeMuted` chip that collapses on application rows. Revealed BitLocker keys sit on a `TintGreen` surface (radius 8), the card's one accent. |
| Lens device card | *(no catalogue entry)* | Two lines, three tiers: model in `TitleTextPrimary` (it separates the machines), `Tag <service tag>` mono, last-seen sans, both tertiary. OS lives in the row tooltip. Collapsing separators so a missing value leaves no orphaned dot. |
| Elevation state | Status Feedback | A standing amber `LIMITED` badge (`BadgeAmber` recipe) beside the wordmark, full sentence in the tooltip. Driven by `ElevationContext::IsElevated()`, never by `runAsAdmin` — the badge reports what the process actually got. |
| Surfacing from tray | Modal Windows | The deferred sign-in/update prompt runs **before** `Window.Show()`, matching the cold start. A cancelled sign-in still shows the main window. |
| Tokens | *(visual language)* | Text scale: `TextPaneTitle` 18/Bold > `TextTitle` 16 > `TextSubtitle` 14 > `TextBody` 13; stat tiles use `StatValue` + `MicroLabel`. Badges are the 3-colour `Badge*` family — never hand-rolled. Radii: 10 cards, 8.4 controls/chips, 7 dropdown rows, 6 small chips. Glyphs pin `FontSymbol`. |

## Colour hierarchy (button variants)

Status accents are defined once in `UIColors.xaml`; `HomePresenter.SeedRowPalette`
hands `HostViewModel` frozen brushes — no hexes live outside `src/UI/Styles`.

- **Reserve saturated colour for meaning or the one primary action.** Status badges
  and the primary CTA earn colour because it encodes something.
- **Decorative tints are the anti-pattern.** Secondary/utility actions use the
  neutral `ButtonSecondary` (or `ButtonOutline`/`ButtonGhost`) so they read as
  subordinate — detail-pane header buttons, the Lens card's `Reveal Key`/`QR`.
- **Chrome is neutral.** Window and popup borders are the `PanelBorder` hairline.

## Popup chrome contract

Every popup — the modal `DialogWindow` and the shell overlay cards (settings, QR,
reset) — shares one chrome:

- **X, always, flush in the top-right corner**, 50 wide, filling the header row:
  `controlButton` on square windows, `controlButtonCardClose` on radius-10 cards.
- **Radius two tiers:** top-level windows `CornerRadius="0"` (DWM rounds the
  frame); in-window overlay cards radius 10 (the `Card` recipe).
- **Header is one 48px row:** title beside the X, vertically centered,
  `TextPaneTitle` at a 24px inset, ellipsis + tooltip when dynamic. On
  `DialogWindow` the row doubles as the drag region. The header may carry that
  popup's page switcher, centered (nav that scrolls away is nav you cannot reach).
- **Content gutters are 24px.**
- **Footers hold decisions only** — an action-named primary and a verdict
  secondary. A dismiss-only "Close" button is banned: X + Esc (+ backdrop on
  overlays) already dismiss.
- **One tint per row, marking the row's primary action** (`Run` =
  `ButtonTintSuccess`, `Add`/`Unlock` = `ButtonTintPrimary`, `Clear Selected` =
  `ButtonTintDestructive`). The `ButtonTint*` family **is** the CTA tier; the old
  solid `ButtonPrimary`/`ButtonDestructive` styles were removed.
- **Overlay Esc discipline:** an overlay's Esc `KeyBinding` only fires if focus is
  inside it, so every overlay focuses its card on show. The guided tour is the
  documented exception (no X, inert backdrop, Skip/Esc exit).

## Working notes

- Guided Tour: one idea per step, short, always escapable, self-paced.
- Autocomplete: order by relevance, group into categories, Esc dismisses.
  (Matched-substring highlighting: not implemented; revisit at real fleet sizes.)
- Match the treatment to the task; don't over-design utilitarian surfaces.
- Spacing defaults (the Fluent 2 layer): a title never hugs its top edge; a label
  and its value differ in **colour, not just size** (MicroLabel grey over a
  `TitleTextPrimary` value); data-holding tiles wear the `Card` recipe
  (`SurfaceMuted` only for a dialog's transient rows); chrome aligns to the content
  column; anything in a fixed-height bar keeps visible air above and below.
