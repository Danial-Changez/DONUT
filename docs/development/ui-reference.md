---
title: UI reference
description: The canonical UI pattern source for DONUT, the rules applied so far, and the Arcane visual language.
---

**Canonical source for all UI/UX work on DONUT: <https://ui-patterns.com/patterns>.**
Find the established pattern before designing, follow its guidance, and heed its
anti-pattern warnings. Rationale for the calls below lives in
[Design decisions](./decisions.md#ui-decisions).

**Reference stack, in priority order:**

1. **ui-patterns.com**: behaviour and structure (which pattern, when).
2. **Arcane / shadcn tokens** (`src/UI/Styles`): the look (palette, radii, type
   tiers, button variants). The primary styling authority.
3. **Fluent 2**: what the first two are silent on, such as spacing rhythm,
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
BIOS, DCU, QR, AD). Two all-caps tiers survive as visual tokens rather than prose:
`MicroLabel` over a data tile's value (`BATTERY HEALTH`, `AVAILABLE UPDATES`) and
the status badges (`LIMITED`, `VERIFIED`). Settings card headings are
`SettingsSectionLabel` in Title Case (`Startup & Tray`, `Diagnostics`); an eyebrow
on every card read as noise. A truncated label ends in `…`, never `...`.

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
| Search dropdown | Autocomplete | Enter acts on real rows only: pre-select is the top-ranked computer, else the top user; it can never fabricate a machine. Picking a computer *is* the add. The one non-row Enter is a pasted multi-token list. Sections cap at `MaxDropdownRows` (15) with a non-pickable `+N MORE` header; the list pixel-scrolls; popup closes on Esc, focus loss, or deactivation. |
| Machine pane header | Reduction | Pane title + right-aligned `Clear` (`ButtonSecondary`), mirroring the detail pane's header offsets. Each card carries its own ✕ (the `fieldClearButton` recipe, one clear-X affordance app-wide); a running host toasts and stays. No filter tabs; the list keeps its fixed status-grouped sort (`MachineListShaper.StatusRank`, attention first). |
| Empty machine list | Blank Slate | "No machines yet" with numbered first steps. |
| Onboarding | Guided Tour | One step at a time, spotlight + callout, always escapable. Not all-at-once coachmarks. |
| Job progress | Completeness Meter | One live bar (`DetailProgress`, atop the terminal), single driver `InventoryPresenter.ShowJobProgress`. Determinate from dcu's percent; `DcuProgress.IsInstalling` flips it indeterminate (installs report no sub-percentage). The remote dcu log is cleared before tailing so the bar never replays the prior run. |
| Toasts | Status Feedback | One accent, two carriers: the 4px bar and the title. The border is `PanelBorder` and there is no glow. The card is a polite live region (`AutomationProperties.LiveSetting`). |
| Update outcome | Status Feedback | An `Updating` toast as the download starts (the download blocks the UI thread, so `UpdatePresenter.PaintNow` pumps the toast onto the screen first), and on the relaunch a success or warning toast naming the version landed on, from a one-read marker (`SelfUpdateService.TakePendingUpdate`). The install itself runs with DONUT closed: msiexec's passive bar covers the MSI path, and the zip path stays silent. |
| Motion | *(a11y)* | Every storyboard waits on `SystemParameters.ClientAreaAnimation`, the OS "show animations" setting, as a `MultiDataTrigger` condition on `{Binding Source={x:Static SystemParameters.ClientAreaAnimation}}`. With it off, a toast shows and hides at once and the progress pulse holds still. |
| Focus and names | *(a11y)* | Every focusable control carries `FocusRingVisual`, the `controlButton` family and `Hyperlink`s included. Every icon-only control carries `AutomationProperties.Name`, because a `ToolTip` reaches UIA as help text. |
| Window controls | Reduction | Windows chrome: neutral hover (`TitleTextPrimary`) on minimize, maximize, and the help trio. Red is Close's alone. |
| Settings toggles | *(Fluent: one hit target)* | The label is the `ToggleButton`'s `Content`, so switch and label are one target. A tooltip that explains a setting sits on the switch. |
| Terminal log | *(console convention)* | Every line is a typed `LogLine`: severity colour **plus** an `[Error]`/`[Warn]` text tag, so colour is never the only carrier. Uniform dim `HH:mm:ss` stamps; chromeless virtualized ListBox (Recycling); `Copy` replaces drag-selection. Severity is decided at the source (`AsyncJob.DrainStream`); the return code stays the authority on failure. |
| Available updates card | Blank Slate | Hint until results; fills from the last completed scan's report via one driver (`HomePresenter.RenderUpdatesFromReport`). Selection re-renders what a prior scan wrote; reading is never a re-scan. |
| Identity verdict | Progressive Disclosure | Compact colour pill (`VERIFIED`/`UNVERIFIED`/`WRONG MACHINE`) with the full sentence in its tooltip, refreshed the moment the verdict lands; the apply gate reads the verdict independently (a consented apply waits on a running check and starts only on `VERIFIED`), so the compact display costs no safety. |
| Storage folder selection | *(no catalogue entry)* | Themed `ModernCheckBox` only. Protected rows render no checkbox (the `Auto` column collapses, so the indent itself signals actionable). Cascade is downward only; unchecking a child releases any checked ancestor. `CollectSelected` clears only explicitly checked subtrees. |
| Debug toggle | Good Defaults | Verbose logging defaults off; the override is one live toggle flip (workers included) or `Start-Donut -DebugLog` for a session-only force-on. |
| Dialogs (`DialogWindow`) | Modal Windows | One shared modal for confirm/alert/update. X + Esc, no minimize. Action-specific primary label ("Clear"/"Apply", never "Confirm"), 5-arg `ShowConfirmation` at every call site. Tint variants, not solid fills; `ButtonTintDestructive` for irreversible actions (folder clears, both apply confirms). The presenter builds the VM (resolving `PrimaryStyle`); the view binds it, with no `FindName` style-poking. A remember checkbox (`HasRemember`) is a `ModernCheckBox` in its own row at the 24px gutter above the footer, Title Case like any setting label, never inside the footer, which holds decisions only. The update prompt's version pair is a `Card` row (`HasVersionCard`), old to new with the arrow reversing on a rollback, and the release page rides that row as a `Hyperlink`, since a message never restates its own title or button. |
| Truncatable text | Progressive Disclosure | Ellipsis (TextBlocks) or clip (`SelectableText` TextBoxes) + a tooltip bound to the same value. Copy-valuable values stay `SelectableText`. Same-value tooltips stay unconditional, since WPF cannot gate them ([why](./decisions.md#tooltips-on-untrimmed-text-stay-unconditional)). A tooltip that adds nothing to a labelled button is banned. |
| Title bar | Reduction | One 36px control bar: wordmark left at the content column's 25px inset, passive (`IsHitTestVisible=False`) so the bar stays the DragMove surface; window controls dock right. |
| Detail header | *(Fluent: label/value)* | Hostname over IP and uptime (`OvUptime`), the two liveness facts. The DISK tile's sub-line is the disk total, so its label and value agree. |
| Temp-password overlay | Modal + Input Prompt/Feedback + Good Defaults | Standard overlay anatomy (48px header, title names the target, flush corner X). UPN/SAM as two `Card` tiles (person-fields pairing); password field watermarked mono; under 8 chars the field takes the `Tag='error'` border **and** an inline `AccentRed` line under it names the rule (`ResetVm.PasswordError`), since a colour is never the only carrier (watermark clears on **focus**); Copy/QR disabled until a password exists; change-at-logon pre-checked. Generate left, `ButtonTintDestructive` "Reset Password" right; no Close button. Success keeps the card open; closing wipes the secret. |
| QR overlay (BitLocker) | *(hardware constraint)* | Inverted by choice: violet modules on the dark card, 12px quiet zone. Field-gated on the hardware scanner: if it fails the scan test, revert to dark-on-light (`QrModule*` keys), don't tweak colours. |
| Lens person pane | Card layout | The person's facts (EMAIL/MANAGER/SAM/OFFICE) sit in a 2×2 grid of dense bordered `Card` tiles (`Padding="12,8"`, 6/6 gutters), the temp-password overlay's person-fields pairing: `MicroLabel` over a `TitleTextPrimary` value, identity strings (email, SAM) in mono. The DEVICES/SOFTWARE header toggles the list slot, whose rows (devices and software alike) are borderless `SurfaceSolid` at radius 8, a half step above the pane, below the fact tiles' bordered cards, and far enough from the `Secondary` button gray that the rows' `ButtonSecondary` actions keep their contrast (the machine detail's lighter `PanelBackgroundHover` sat too close to it, and anything below the pane fill reads as a hole). Software rows share the device rows' column anatomy: name over collection, the package program as a right-aligned `BadgeMuted` chip that collapses on application rows. Revealed BitLocker keys sit on a `TintGreen` surface (radius 8), the card's one accent. |
| Lens device card | *(no catalogue entry)* | Two lines, three tiers: model in `TitleTextPrimary` (it separates the machines), `Tag <service tag>` mono, last-seen sans, both tertiary. OS lives in the row tooltip. Collapsing separators so a missing value leaves no orphaned dot. |
| Copyable values | *(Fluent: copy affordance)* | A short single-line value **is** the copy target (`CopyableValue`), not a glyph beside it: plain at rest, a `SurfaceMuted` pill on hover, a `Copy` tooltip. `Tag` carries the clipboard payload, because the rendered string may be decorated (`DetailTitle` appends an offline suffix; `TagText` and `OvModelSub` prefix `Tag `). One window-level `MouseLeftButtonUp` handler serves them all, since Lens rows are template-built; it copies only when `SelectionLength` is 0, so a drag still selects. Only a value that gets pasted into another tool earns it; the BitLocker key keeps a glyph, being the one that wraps. |
| Startup errors (`ErrorDialog`) | Modal Windows | A hand-themed WinForms window, since these fire before WPF and two of them fire *because* it failed. It draws the same chrome as `DialogWindow` (48px header, the X as a painted 10px glyph with the Destructive hover, 24px gutters) and sets its text in the embedded Geist through GDI+; the details box keeps the mono fallback. Popup chrome contract, and **no footer at all**: an error carries no decision, and a dismiss-only button is banned. One-line reason, a short action line in the docs' voice, then the exception behind a Details toggle on `TerminalBackground`, read-only so it can be pasted. Every call site passes reason and detail separately. |
| Elevation state | Status Feedback | A standing amber `LIMITED` badge (`BadgeAmber` recipe) beside the wordmark, full sentence in the tooltip. Driven by `ElevationContext::IsElevated()`, never by `runAsAdmin`, so the badge reports what the process actually got. The running version sits beside it in the same tier as a `ButtonBadge`, copying on click, because reporting one is the only reason it is on screen. |
| Surfacing from tray | Modal Windows | The deferred sign-in/update prompt runs **before** `Window.Show()`, matching the cold start. A cancelled sign-in still shows the main window. |
| Tokens | *(visual language)* | Fonts: Geist and Geist Mono, embedded under `src/UI/Styles/Fonts` (OFL), the docs site's families; Segoe UI and Cascadia Mono fall back. One type ladder, 11 / 12 / 13 / 14 / 16 / 18, as roles in `Tokens.xaml`: `TextPaneTitle` 18/Bold > `TextTitle` 16 > `TextSubtitle` 14 > `TextBody` 13 > `TextMeta` 12 > `TextCaption` 11. Stat tiles use `StatValue` (18) + `MicroLabel` (11), buttons 13 Medium. A `TextBlock` takes a role, not an inline `FontFamily`/`FontSize`/`Foreground` triple, unless a trigger restyles it (a triggered `Style` cannot `BasedOn` a `DynamicResource`). A `TextBox` value stays inline, on the ladder. Badges are the 3-colour `Badge*` family, never hand-rolled. Radii: 10 cards, 8.4 controls/chips, 7 dropdown rows, 6 small chips. Glyphs pin `FontSymbol`. |

## Colour hierarchy (button variants)

Status accents are defined once in `UIColors.xaml`; `HomePresenter.SeedRowPalette`
hands `HostViewModel` frozen brushes, so no hexes live outside `src/UI/Styles` in
the PowerShell and XAML tree. The C# launcher (`SplashForm`, `ErrorDialog`,
`TrayTheme`, `SmoothProgressBar`) runs before WPF and carries a hand copy of the
same values. A token change lands there too.

- **Reserve saturated colour for meaning or the one primary action.** Status badges
  and the primary CTA earn colour because it encodes something.
- **Decorative tints are the anti-pattern.** Secondary/utility actions use the
  neutral `ButtonSecondary` (or `ButtonOutline`/`ButtonGhost`) so they read as
  subordinate: detail-pane header buttons, the Lens card's `Reveal Key`/`QR`.
- **Chrome is neutral.** Window and popup borders are the `PanelBorder` hairline.

## Popup chrome contract

Every popup, the modal `DialogWindow` and the shell overlay cards (settings, QR,
reset) alike, shares one chrome:

- **X, always, flush in the top-right corner**, 50 wide, filling the header row:
  `controlButton` on square windows, `controlButtonCardClose` on radius-10 cards.
- **Radius two tiers:** top-level windows `CornerRadius="0"` (DWM rounds the
  frame); in-window overlay cards radius 10 (the `Card` recipe).
- **Header is one 48px row:** title beside the X, vertically centered,
  `TextPaneTitle` at a 24px inset, ellipsis + tooltip when dynamic. On
  `DialogWindow` the row doubles as the drag region. The header may carry that
  popup's page switcher, centered (nav that scrolls away is nav you cannot reach).
- **Content gutters are 24px.**
- **Footers hold decisions only**: an action-named primary and a verdict
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
- Preview a view with the full theme, no app launch: `pwsh -Sta -File
  tools\Show-View.ps1` (DialogWindow with sample data; `-View` picks another,
  `-ErrorDialog` builds and shows the C# launcher dialog, `-Screenshot` saves a
  PNG and closes).
- Spacing defaults (the Fluent 2 layer): a title never hugs its top edge; a label
  and its value differ in **colour, not just size** (MicroLabel grey over a
  `TitleTextPrimary` value); data-holding tiles wear the `Card` recipe
  (`SurfaceMuted` only for a dialog's transient rows); chrome aligns to the content
  column; anything in a fixed-height bar keeps visible air above and below.
