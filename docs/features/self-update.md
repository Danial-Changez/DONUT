---
title: Self-update & rollback
description: How DONUT signs in, finds new releases, and updates or rolls back to a different version.
---

DONUT keeps itself current from your org's **GitHub Releases**.

1. On startup, DONUT signs you in with your GitHub App. You only see the sign-in
   prompt when the saved token is missing or expired.
2. It compares your installed version to the latest release.
3. If they differ, it offers to update, or to **roll back** when the latest
   release is older than what you have (how a bad release gets pulled).
4. The download is integrity-checked before it installs.
5. DONUT closes, the installer runs, and DONUT opens again on its own.

A Windows notification (Action Center) says when the download starts, since the
app closes for the install and only the shell can carry that status. Once DONUT
reopens, an in-app toast says which version it is on now, or that the update did
not complete - it waits for the window to show, so it cannot expire unseen.

The prompt shows the version you are on and the one you would move to, with a link
to that release's notes on GitHub. A rollback shows the same pair the other way
round, and says **Roll Back** rather than **Update Now**.

Your settings, machine list, logs, and reports are never touched by an update.

## Updating without being asked

The update prompt carries an **Install Updates Automatically** checkbox, and
**Settings → Updates → Automatic Updates** is the same switch. With it on, a
newer release installs the moment DONUT finds one, no prompt.

A **rollback never happens automatically**. Going backwards is a decision, the one
you make when a release is pulled, so it always asks, whatever this is set to.

## Beta channel

**Settings → Updates → Beta Channel** puts DONUT on the beta stream, where every
build is published as it lands rather than only the finished ones. Betas carry the
same integrity check; they are newer, and less proven.

Turning it back off offers the current stable build as a **rollback**, since the
stable release is older than the beta you are running. Nothing else changes: both
channels share the same settings, machine list and reports.

The channel is one choice per machine, not per copy. If you keep a beta install
beside a normal one, beta wins for both while it is on.

To install a beta on a fresh machine, see
[Installation](../get-started/installation.md#testing-a-beta-build).
