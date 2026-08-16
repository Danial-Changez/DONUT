---
title: Releasing
description: Where the version number comes from, how a push becomes a beta, and how a beta is promoted to stable.
---

Every push to `main` publishes a build. `VERSION` holds the series (`2.4`), the
release workflow appends the commit count, and the result is tagged `v2.4.57` and
published as a **prerelease**. Nothing about that artifact is beta-only: it is the
same MSI a stable release ships, from the same `tools/Build-Installer.ps1`.

The third field is a build counter, not a patch level. A fix and a feature both
advance it by however many commits they took, so versions are ordered but not
meaningful - the series is where intent lives, and it is bumped by hand.

## Promoting a beta to stable

A tested build becomes stable by flipping the flag on the release it already is:

```powershell
gh release edit v2.4.57 --prerelease=false --latest
```

No rebuild, no second tag, no version bump: what operators install is the exact
artifact that was tested. `--latest` is what the `releases/latest` endpoint
answers with, and that endpoint is the stable channel's only source.

Bump `VERSION` to the next series once a promotion lands, so the next beta stream
is numbered ahead of the stable build everyone is now on.

## The two channels

| | Stable | Beta |
| :--- | :--- | :--- |
| Reads | `releases/latest` | `releases` (first non-draft) |
| Sees | the release marked latest | prereleases as well |
| Turned on by | default | Settings > Updates > Beta Channel (`betaUpdates`) |

Any version difference prompts, in either direction, so turning the toggle off on
a machine running a prerelease offers the stable build as a rollback. Both
channels download, verify and install the same way.

## Cutting a stable release by hand

Push a `vX.Y.Z` tag. The workflow builds that version and publishes it with
`--verify-tag`, no prerelease flag. This is the path for a release that was never
a beta - a hotfix, or the first release of a series.

`workflow_dispatch` with a version is the dry run: same build, artifact only, no
release and no tag.

## Where a beta gets installed

`tools/Install-Beta.ps1` installs the newest release (prereleases included) into
its own directory, default `C:\Safe\Donut`, and turns the toggle on before first
launch. It is the same MSI with `INSTALLFOLDER` pointed elsewhere, so a tester and
an operator run identical binaries.

Two things keep that install honest:

- The script applies an explicit DACL (SYSTEM and Administrators full, Users read
  and execute). The app tree self-extracts beside the exe and runs elevated, and a
  directory created under `C:\` by a standard user is writable by them, which
  would put a planted DLL next to an elevated process.
- `InstallWorker.ps1` passes the registered `InstallLocation` back as
  `INSTALLFOLDER` on every update, because a major upgrade otherwise resolves the
  default Program Files path and would migrate the install out of its directory.

A beta install shares `%ProgramData%\DONUT\data` with a normal one, so settings,
machine list, logs and reports carry across in either direction.
