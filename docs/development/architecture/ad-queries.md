---
title: AD query rules
description: How DONUT shapes its LDAP filters, what the directory guidance requires, and which choices are measured rather than argued.
---

Every LDAP query DONUT issues was audited against Microsoft's
[Creating More Efficient Microsoft Active Directory-Enabled Applications](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc755809\(v=ws.10\)).
Queries live in two places: the finder (`ActiveDirectoryService.QueryDirectory`,
filters built by `AdFilter` in `src/Models/AdSearchResult.psm1`) and the de-elevated
Lens agent (`Find-Gc` and the per-device reads in `src/Scripts/LensAgent.Common.ps1`).

## The rules

- **Prefix wildcards only.** `(cn=dan*)` uses the attribute index; a medial search
  (`(cn=*dan*)`) cannot without a tuple index, which is a forest-wide schema change.
- **`objectCategory`, not bare `objectClass`.** `objectClass=user` matches users
  **and** computers (computer derives from user). The canonical pair is
  `(&(objectCategory=person)(objectClass=user)…)`; computers are
  `(objectCategory=computer)`.
- **Name the attributes.** `PropertiesToLoad` is always explicit, never a
  full-object read.
- **Bound the search, and bound the display separately.** `SizeLimit` +
  `ClientTimeout` on every searcher. An LDAP cap truncates in server order, not by
  relevance, so the LDAP cap decides who is *considered* (`MaxPerDomain` 25,
  `SizeLimit` 50) and `AdSearchRank` decides who is *shown*. Never conflate the two.
- **No `PageSize` on a capped search.** Paging makes `SizeLimit` be ignored, so a
  small type-ahead query would fetch the whole result set. `ServerPageTimeLimit`
  does nothing without it either.
- **One `(sn=$p*)` clause instead of ANR.** Measured: every extra hit ANR found was
  a surname match, and its schema-level breadth could crowd real people out of the
  per-forest cap. Surname-only hits rank last, inferred rather than read. Re-run
  `tools\Measure-AdSearch.ps1` when the filter changes; details in
  [Design decisions](../decisions.md#anr-measured-and-rejected).
- **Referral chasing stays at the default** (`External`). Measured equal on hit
  counts and ~6 ms apart; the hit count is the test, not the clock.
- **Schema knobs are out of scope.** `searchFlags` and `dsHeuristics` are
  forest-wide directory changes; a fleet tool has no business writing them.

## A forest that cannot answer is not a forest with no matches

`Search` isolates each forest in a try/catch so one down or untrusted directory
cannot fail the others, and failures must stay visible (a misspelt forest name once
returned nothing, silently, for a quarter of every search; see
[Design decisions](../decisions.md#the-misspelt-forest)):

- `ActiveDirectoryService.LastErrors` records each failure as `<domain>: <reason>`,
  reset at the top of every `Search` so a recovered forest stops reporting.
- The worker re-emits them on the **warning stream**, which crosses the runspace
  boundary without polluting the typed result rows.
- `FinderPresenter.ReportForestFailure` drains that stream, logs each, and logs the
  search as `FAILED` rather than `0 hit(s)`.
- The operator is toasted once per forest per session.

Changing a default does not fix an existing install: user settings merge over
defaults, so a wrong value already saved in `config.json` keeps winning.

## Measuring

`tools\Measure-AdSearch.ps1` times all four filter combinations per forest, then a
second untimed pass prints the rows only one filter returned and names the attribute
that pulled each in. The passes are separate on purpose: attributing a match widens
`PropertiesToLoad`, which changes what the DC serialises and would corrupt the
timing.

Trust the four-span breadcrumb
([reading it](./runspaces-and-workers.md#reading-the-ad-search-breadcrumb)) over
totals: the `search` span is uniform across forests, and historical "slow forest"
figures were render cost, not directory cost
([the story](../decisions.md#most-of-a-search-is-not-the-query)).
