---
title: Releasing
description: Where the version number comes from, how a push becomes a beta, and how a beta is promoted to stable.
---

Every merge to `main` that touches code publishes a build. `VERSION` holds the
series (`2.5`), the release workflow appends the commit count, and the result is
tagged `v2.5.57` and published as a **prerelease**. Nothing about that artifact is
beta-only: it is the same MSI a stable release ships, from the same
`tools/Build-Installer.ps1`.

A merge carrying only `docs/` or `web/` changes is not a build: the workflow's
`guard` job diffs what the push brought in and skips the rest when nothing outside
those two directories moved. A path filter cannot do this, because the same `push`
trigger also carries the `v*.*.*` tags that cut stable releases.

`main` requires a pull request and four passing checks (`checks`, `tests (Unit)`,
`tests (Integration)`, `build`), so nothing reaches the beta channel without the
gate having run against what actually landed.

The third field is a build counter, not a patch level. A fix and a feature both
advance it by however many commits they took, so versions are ordered but not
meaningful - the series is where intent lives, and it is bumped by hand. Semantic
versioning does not fit here and a fourth field is worse than useless: the MSI is
the one that has to compare, and it counts three fields
([why](./decisions.md#why-the-third-field-counts-builds-not-patches)).

## Promoting a beta to stable

A tested build becomes stable by flipping the flag on the release it already is:

```powershell
gh release edit v2.5.57 --prerelease=false --latest
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
| Usually installed by | the MSI | `tools/Install-Beta.ps1` (zip) |

`betaUpdates` lives in the shared config, so it is one choice per machine rather
than per copy: while it is on, beta overrules stable for every install on that
machine. `autoUpdate` sits beside it and applies a newer release without prompting,
which is what the update prompt's own checkbox writes.

Any version difference prompts, in either direction, so turning the toggle off on
a machine running a prerelease offers the stable build as a rollback. Both
channels download, verify and install the same way.

## Cutting a stable release by hand

Push a `vX.Y.Z` tag. The workflow builds that version and publishes it with
`--verify-tag`, no prerelease flag. This is the path for a release that was never
a beta - a hotfix, or the first release of a series.

`workflow_dispatch` with a version is the dry run: same build, artifact only, no
release and no tag.

## Two packages, one build

Every release publishes `DONUT.msi` and `DONUT.zip` (each with its own `.sha256`),
built from the same staged payload: the workflow packs `installer\obj\stage`, which
`Build-Installer.ps1` leaves behind, and drops a `VERSION` file in first - the built
version, not the series that the repo root's `VERSION` carries. The zip is the
launcher and its runtime, nothing else: the app tree self-extracts beside the exe on
first run and the data stays in `%ProgramData%`, exactly as an MSI install behaves.

Which package an install applies depends on how it was installed, and
`SelfUpdateService` decides by location: a copy running inside the `InstallLocation`
its uninstall key records is an MSI install and updates through msiexec, and
anything else is a zip install and replaces its own files. Same rule for the version
it compares - the uninstall key for one, the packaged `VERSION` for the other, which
is why a zip install never needs an ARP entry it does not have. Stable therefore
updates by MSI and beta by zip, without either being told which it is.

A promoted beta is still a zip *and* an MSI, since promotion changes a flag rather
than the artifacts: an operator installing it fresh gets the MSI, and the testers
already on it keep updating from the zip.

## Where a beta gets installed

`tools/Install-Beta.ps1` unpacks the newest release (prereleases included) into its
own directory, default `C:\Safe\Donut`, and turns the toggle on before first launch.
The zip rather than the MSI, for two reasons: msiexec owns one install per machine,
so a beta MSI would move an existing stable install rather than stand beside it, and
a beta that lands every commit should not re-run an installer each time.

Three things keep that install honest:

- The script writes an explicit DACL naming two accounts and no well-known SIDs: the
  admin account that ran it owns the directory and is the only one who can write it,
  and the desktop's own user gets read and execute so a de-elevated launch still
  works. The app tree self-extracts beside the exe and runs elevated, and a directory
  created under `C:\` by a standard user is writable by them, which would put a
  planted DLL next to an elevated process. Run it as the account DONUT elevates to.
  Nothing grants SYSTEM or the Administrators group, because an account that can
  bypass a DACL was never limited by one being there.
- The update unpacks over the directory rather than replacing it, so the extracted
  app tree and the downloaded WizTree survive, and it asks for elevation the way
  msiexec would have (silent when DONUT already runs elevated).
- `InstallWorker.ps1` passes the registered `InstallLocation` back as
  `INSTALLFOLDER` on the MSI path, because a major upgrade otherwise resolves the
  default Program Files path and would migrate an install out of its directory.

Both installs share `%ProgramData%\DONUT\data`, so settings, machine list, logs and
reports carry across - including the beta toggle, which is one machine-wide choice
rather than one per copy.
