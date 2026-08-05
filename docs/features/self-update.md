---
title: Self-update & rollback
description: How DONUT signs in, finds new releases, and updates or rolls back to a different version.
---

DONUT keeps itself current from your org's **GitHub Releases**.

1. On startup, DONUT signs you in with your GitHub App — you only see the sign-in
   prompt when the saved token is missing or expired.
2. It compares your installed version to the latest release.
3. If they differ, it offers to update — or to **roll back**, when the latest
   release is older than what you have (how a bad release gets pulled).
4. The download is integrity-checked before it installs.

Your settings, machine list, logs, and reports are never touched by an update.
