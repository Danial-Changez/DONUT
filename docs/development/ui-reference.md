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
| Machine-list status filter | **Module Tabs** | The segmented status chips act as the list module's header, with the action (Clear) on the right. |
| Empty machine list | **Blank Slate** | The "No machines yet" guidance with numbered first steps. |
| First-run onboarding | **Guided Tour** (one step at a time, spotlight + callout, always escapable) | Deliberately **not** all-at-once **Coachmarks**, which ui-patterns.com calls "borderline an anti-pattern" for overloading/obstructing. |

## Working notes distilled from the patterns

- **Guided Tour**: one idea per step, keep it short (people hold ~3–4 things at once), always
  allow escape/skip, self-paced. Offer Skip once; Esc exits throughout.
- **Autocomplete**: order by relevance, group into categories, highlight the match, Esc to dismiss.
- Match the treatment to the task; don't over-design utilitarian surfaces.
