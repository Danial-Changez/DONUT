# CI/CD Pipeline Flow

## Overview
The app auto-updates from GitHub Releases using a GitHub App with Device Flow. No server backend is required. On startup, the app checks the latest release, compares versions, and installs the target MSI if different (supports update or rollback by tag).

## Prerequisites
- A GitHub App configured for Device Flow and authorized by organization or repository owners.

## Tokens and Security
- `Updater.ps1` requests a user access token and a refresh token via the GitHub App (Device Flow).
  - Access token: used to call GitHub APIs; expires in ~8 hours.
  - Refresh token: used to mint a new access/refresh pair; expires in ~6 months.
- Both tokens are encrypted with DPAPI (CurrentUser scope). Only the admin account that acquired them can decrypt.

## Runtime Flow
1. On startup, the app locates and decrypts the stored tokens (if present and not expired).
   - If not, the login page launches and Device Flow is initiated.
3. It fetches the latest release metadata from GitHub.
4. If the latest release tag differs from the installed version, it downloads/uses the corresponding MSI and initiates install:
   - This enables both forward updates and rollbacks by release tag.

## Installation Handoff
- The MSI execution is delegated to `InstallWorker.ps1`, copied to:
  - `%LOCALAPPDATA%\DONUT`
- `InstallWorker.ps1` performs the install/update, then relaunches the app on completion.

## User Data Preservation
- To avoid losing local state across upgrades/rollbacks, the app persists user data under:
  - `%LOCALAPPDATA%\DONUT\User Data`
- Persisted items:
  - `config.txt`
  - `logs\` (all log files)
  - `reports\` (all generated reports)
- On startup, `MainWindow.ps1` restores these items (creating folders if missing) so updates do not impact user settings, logs, or saved reports.

## Sequence Summary
1. GitHub App created (Device Flow).
2. Organization/Repository owners authorize the app.
3. `Updater.ps1` acquires tokens and stores them encrypted (DPAPI CurrentUser).
4. App start: decrypt → query latest release → compare version → install MSI if different.
5. MSI install via `InstallWorker.ps1` under `%LOCALAPPDATA%\DONUT` → relaunch.

Notes
- Device Flow avoids hosting a backend and fits locked-down environments.
- Token refresh is automatic when needed; failed decryption or expiry triggers a new device-flow sign-in.
