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

## Measured, not argued

Both of these change **which results come back**, so both are decided on hit counts, not just
the clock. `tools\Measure-AdSearch.ps1` times all four combinations per forest and prints
elapsed beside hits:

```powershell
pwsh -File tools\Measure-AdSearch.ps1
```

- **ANR.** `(anr=dan)` is a single optimized clause across the naming attributes, and it is
  the only shape that handles `first last` (it matches `givenName` AND `sn`). The current
  four-clause OR cannot, which is why a full-name search returns almost nothing today. Its
  cost is breadth: the ANR set is schema-level and also covers
  `physicalDeliveryOfficeName` and `proxyAddresses`, so a three-letter office prefix could
  crowd out real people under the per-forest cap. **`userPrincipalName` is not in the ANR
  set**, so any adoption keeps a UPN clause ORed alongside. Adopt only where ANR is faster
  **and** returns at least as many hits.
- **Referral chasing.** `DirectorySearcher.ReferralChasing` defaults to `External`. AD reaches
  child domains through subordinate references, so `None` is only safe where the hit count is
  unchanged. Fewer hits means referrals are load-bearing for a child domain and chasing stays
  on. The count is the test, not the clock.

## Forest latency is not a query problem

Per-forest search times are stable and differ by forest, measured across six searches:
`forest-b` ~167ms, `prod` ~331ms, `forest-c` ~394ms, `forest-d` ~578ms. Raising the interactive pool so a
whole fan-out dispatches at once took roughly 110ms off `forest-d` and left the rest, so what
remains is that forest's own latency rather than scheduling. See
[Runspaces and workers](./runspaces-and-workers.md) for the pool sizing and why the fan-out
earns its keep. The dropdown renders each forest as it lands, so a slow forest delays only its
own rows.
