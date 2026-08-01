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
- **Always bound the search.** `SizeLimit` plus `ClientTimeout` on every searcher. The finder
  caps at `MaxPerDomain * 2`.
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

- **ANR.** `(anr=dan)` is a single optimized clause across the naming attributes, and it is
  the only shape that handles `first last` (it matches `givenName` AND `sn`). The current
  four-clause OR cannot, and it also cannot reach a `Smith, Daniel` whose `cn` never starts
  with the typed prefix. Its cost is breadth: the ANR set is schema-level and also covers
  `physicalDeliveryOfficeName` and `proxyAddresses`, so a three-letter office prefix could
  crowd out real people under the per-forest cap. **`userPrincipalName` is not in the ANR
  set**, so any adoption keeps a UPN clause ORed alongside. Adopt where ANR is **not slower**
  and the rows only it finds are **people, attributed to a name attribute** - the script
  flags a row whose only match is an office or a mail alias, and anything listed under
  *Only the current filter found* is a person ANR would lose.
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

That leaves roughly **250-390ms per forest per search that is not the directory**. Two
contributors were identified and fixed on the spot: the search poll had been raised to 150ms,
which is both real latency *and* inflation, because the elapsed is taken when the poll notices
rather than when the job finished; and the debounce had been raised to 250ms, which delays
every search before it starts. The rest is what the four-span breadcrumb exists to find - see
[Reading the AD search breadcrumb](./runspaces-and-workers.md#reading-the-ad-search-breadcrumb).

Do not re-quote the old per-forest figures (`forest-b` ~167 / `prod` ~331 / `forest-c` ~394 /
`forest-d` ~578). They were taken while `forest-b` was misconfigured and answering nothing, and with
the 150ms poll adding up to a tick of measurement error to every one of them.

The dropdown still renders each forest as it lands, so a slow forest delays only its own rows.
