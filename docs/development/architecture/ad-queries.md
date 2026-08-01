---
title: AD query rules
description: How DONUT shapes its LDAP filters, what the directory guidance requires, and which choices are measured rather than argued.
---

Every LDAP query DONUT issues was audited against Microsoft's
[Creating More Efficient Microsoft Active Directory-Enabled Applications](https://learn.microsoft.com/en-us/previous-versions/windows/it-pro/windows-server-2003/cc755809\(v=ws.10\)).
The rules below are what that audit settled. Two questions it could not settle by reading are
measured instead, with a script to re-run them.

Queries live in two places: the finder (`ActiveDirectoryService.QueryDirectory`, filters built
by `AdFilter` in `src/Models/AdSearchResult.psm1`) and the de-elevated Lens agent
(`Find-Gc` and the per-device reads in `src/Scripts/LensAgent.Common.ps1`).

## The rules

- **Prefix wildcards only.** `(cn=dan*)` uses the attribute index. A medial search
  (`(cn=*dan*)`) cannot, unless that attribute carries a tuple index, which is a schema
  change with forest-wide cost. Every filter DONUT sends is a prefix match.
- **`objectCategory`, not bare `objectClass`.** `objectClass=user` matches **users and
  computers**, because computer derives from user in the schema. `objectCategory` is
  single-valued and indexed. The canonical "users, not computers, not contacts" pair is
  `(&(objectCategory=person)(objectClass=user)…)`, and both the finder and the agent use it.
  Computers are `(objectCategory=computer)`.
- **Name the attributes.** `PropertiesToLoad` is always explicit, never a full-object read.
- **Always bound the search - and bound the *display* separately.** `SizeLimit` plus
  `ClientTimeout` on every searcher; the finder caps at `MaxPerDomain * 2`. An LDAP size cap
  truncates in **server order, not by relevance**, so a search that reaches its cap drops
  people arbitrarily and the one you wanted has no better odds than anyone else. `prod` filled
  16 of 16 for a three-letter prefix, then 24 of 24, so `MaxPerDomain` is now **25**
  (`SizeLimit` 50). The two bounds do different jobs and must not be conflated: the LDAP cap
  decides who is *considered*, `AdSearchRank` decides who is *shown*. Widening a filter
  against a tight LDAP cap makes the search quietly worse; widening it against a generous one
  costs only rows on the wire.
- **Do not add `PageSize` to a capped search.** Setting it enables paging and makes
  `SizeLimit` be **ignored**, so a "small" type-ahead query would fetch the whole result set.
  `ServerPageTimeLimit` has no effect without it either, so it is not a way to bound a slow
  DC. `Find-Gc` had a `PageSize` alongside a `FindOne` and it did nothing but cost.
- **Schema knobs are out of scope.** `searchFlags` (indexing, ANR membership, tuple indexes)
  and `dsHeuristics` (suppressing ANR first/last matching) are forest-wide directory changes.
  A fleet tool has no business writing them.

## A forest that cannot answer is not a forest with no matches

`Search` isolates each forest in a try/catch so one down or untrusted directory cannot fail
the others. The catch logged a warning and moved on, but `AdSearchWorker.ps1` constructs the
service with a **null logger**, so `LogService.Coalesce` turned that warning into a no-op:
an unreachable forest produced no log line, no error, and zero rows. It read exactly like a
forest that matched nothing, which is how a **misspelt forest name went unnoticed** - the
default said `forest-b.contoso.com` when the directory is `forest-b.contosogroup.com`, and one
quarter of every search had been quietly returning nothing.

- `ActiveDirectoryService.LastErrors` records each failure as `<domain>: <reason>` and is
  reset at the top of every `Search`, so a recovered forest stops reporting.
- The worker re-emits them on the **warning stream**, which crosses the runspace boundary
  without polluting the typed result rows the caller maps.
- `FinderPresenter.ReportForestFailure` drains that stream, logs each properly, and logs the
  search as `FAILED` rather than `0 hit(s)`.
- The operator is toasted **once per forest per session**. A permanently unreachable forest
  would otherwise nag on every keystroke, and the first time is when it is news.

**Changing the default does not fix an existing install.** User settings merge over defaults,
so a wrong value already saved in `config.json` keeps winning; correct it there or in
Settings.

## Measured, not argued

Both of these change **which results come back**, so neither is decided on the clock.
`tools\Measure-AdSearch.ps1` times all four combinations per forest, then runs a second,
untimed pass that prints the rows only one filter returned and names the attribute that
pulled each one in:

```powershell
pwsh -File tools\Measure-AdSearch.ps1
```

The two passes are separate on purpose. Attributing a match needs `givenName`, `sn`,
`proxyAddresses` and `physicalDeliveryOfficeName` loaded, and widening `PropertiesToLoad`
changes what the DC serialises back - folding it into the timed path would corrupt the
measurement.

- **ANR: measured, and rejected in favour of one explicit clause.** `(anr=dan)` returned 15
  hits on `forest-b` against the four-clause filter's 10, and the identity pass showed **every
  one of the five extras was a surname match**. Nothing came from ANR's other attributes.
  So the filter gained `(sn=$p*)` and ANR stayed out:
  - ANR's headline feature is splitting `first last` across `givenName`/`sn`. That buys
    nothing here - `displayName` in these forests is `First Last`, so the existing
    `displayName=` clause already answers a full-name search, and measurement confirmed ANR
    and the current filter returning identical hits for `danial changez`.
  - Its cost is breadth. The ANR set is schema-level and also covers
    `physicalDeliveryOfficeName`, `proxyAddresses` and `legacyExchangeDN`, so a three-letter
    office prefix could crowd real people out of the per-forest cap - for a recall gain that
    one indexed `sn` clause delivers on its own.
  - **`userPrincipalName` is not in the ANR set**, so adopting it would also have meant
    keeping a UPN clause ORed alongside anyway.

  Re-run the script if the filter changes: anything ANR still finds that `sn` does not is
  worth a look, and anything under *Only the current filter found* is a person it would lose.

  **Adding `sn` moved a cost from recall to presentation, and that had to be paid too.**
  A surname hit is worth having, but people type a first name far more often, so
  `AdSearchRank` orders rows by where the prefix landed - `displayName`, then `cn`/`name`,
  then `sAMAccountName`, then `userPrincipalName`, then surname-only last. That last tier is
  **inferred rather than read**: `sn` is deliberately not in `PropertiesToLoad`, so a row
  matching none of the four visible fields can only have arrived via the `sn` clause. It
  costs nothing per search and needs no extra attribute. A forest that stores `cn` as
  `Last, First` surfaces the surname in a field the finder already reads, and those rows
  correctly rank as visible matches rather than being demoted.
- **Referral chasing.** `DirectorySearcher.ReferralChasing` defaults to `External`. AD reaches
  child domains through subordinate references, so `None` is only safe where the hit count is
  unchanged. Fewer hits means referrals are load-bearing for a child domain and chasing stays
  on. The count is the test, not the clock. Measured: counts identical everywhere and `None`
  won by ~6ms, which is far under the 150ms bar - so it stays at the default.

## Most of a search is not the query

An earlier version of this page credited the residual per-forest time to forest latency.
Measurement says otherwise, and the gap is large:

| | prod | forest-b | forest-c | forest-d |
|---|---|---|---|---|
| LDAP alone (`Measure-AdSearch.ps1`) | ~90ms | ~105ms | ~90ms | ~205ms |
| What `Donut.log` recorded for the same search | 337ms | - | 378-444ms | 539-601ms |

That leaves roughly **250-390ms per forest per search that is not the directory**. The
[four-span breadcrumb](./runspaces-and-workers.md#reading-the-ad-search-breadcrumb) found it,
and it was not the directory or the pool - it was the dropdown re-rendering per forest:

```
AD search prod.contoso.com  'dan': 392ms (queue  59, search 246, rows 61, notice  65), 16 hit(s)
AD search forest-b...       'dan': 643ms (queue  65, search 236, rows 46, notice 297), 10 hit(s)
AD search forest-c.local   'dan': 736ms (queue  78, search 231, rows 32, notice 395),  6 hit(s)
AD search forest-d.local    'dan': 857ms (queue 133, search 204, rows  2, notice 518), 10 hit(s)
```

Add each row's `queue + search + rows` and all four workers finished within **27ms of each
other** (366 / 347 / 341 / 339). The totals still spread across 465ms, entirely in `notice` -
because `PollSearch` called `RenderDropdown` per landed leg, on the UI thread, before reading
the next one. The confirmation is in the same log: a `danial` fan-out returning 2/0/0/0 hits
had almost nothing to draw, and its notices were a flat 33 / 65 / 58 / 66.

**`search` is also uniform (~170-246ms) across every forest, so `forest-d` is not the slow one.**
That belief came from totals, which were mostly render. The in-app span runs higher than the
script's because `Measure-AdSearch.ps1` times `UserFilter` alone while the app sends
`CombinedFilter` - computers *and* users in one query.

Fixed since: the dropdown renders once per poll tick, the poll and debounce raises were
reverted, and `AD dropdown render` now logs its own cost so the next claim is checkable.

Do not re-quote the old per-forest figures (`forest-b` ~167 / `prod` ~331 / `forest-c` ~394 /
`forest-d` ~578). They were taken while `forest-b` was misconfigured and answering nothing, and with
the 150ms poll adding up to a tick of measurement error to every one of them.

The dropdown still renders each forest as it lands, so a slow forest delays only its own rows.
