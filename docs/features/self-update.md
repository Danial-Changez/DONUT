---
title: Self-update & rollback
description: GitHub App device-flow sign-in, release discovery, SHA-256-verified MSI updates, and rollback by tag.
---

DONUT keeps itself current from your org's **GitHub Releases**.

## How updating works

1. On startup, DONUT authenticates via your GitHub App (Device Flow) — the stored
   token is DPAPI-protected per user, so you only sign in when it's missing or
   expired.
2. It compares the installed version (registry) to the latest release tag.
3. If they differ, it prompts to update (or **roll back**, when the latest tag is
   older than the installed version — useful for pulling a bad release).
4. The MSI asset is downloaded to a staging folder, its **SHA-256 verified**, and
   installed via `msiexec` with a basic progress UI. User data under
   `%LOCALAPPDATA%\DONUT` is never touched.

## Publishing an update (maintainers)

- Build the MSI with the Product Version set to the release tag.
- Create a GitHub release with that tag and upload the MSI asset (it must match
  `MsiAssetPattern`, default `*.msi`).
- Users pick up the release on next startup and are prompted to update.

## Under the hood

![Self-update sequence diagram](/DONUT/diagrams/update_sequence_diagram.svg)

*Source: [`update_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/update_sequence_diagram.puml)*
