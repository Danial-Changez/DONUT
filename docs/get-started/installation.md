---
title: Installation
description: Prerequisites and install steps - PsTools, .NET Desktop, the MSI, and the Defender exclusion.
---

## Prerequisites

- **PowerShell 7+** — required for parallel processing (the project currently runs on
  7.5.x).
- **Dell Command Update CLI (`dcu-cli.exe`)** — must be installed on each *target*
  machine.
- **PsExec (Sysinternals PsTools)** — for remote command execution (setup below).
- **.NET Desktop Runtime 10.0+** — needed for WPF in the packaged version.
- **Windows admin access** — every remote operation authenticates as the DONUT process,
  so it needs an account with administrative rights on your fleet targets. DONUT opens
  without elevation and asks for it when you run something remote.
- **GitHub App access** — so your team can sign in via Device Flow and receive
  updates from your org's GitHub Releases.

## Install steps

1. Install the prerequisites above.

2. **Set up PsTools** (skip if PsExec is already on the machine):
   - Download PsTools from
     [Microsoft Sysinternals](https://learn.microsoft.com/en-us/sysinternals/downloads/pstools).
   - Extract the zip anywhere convenient (Documents, Downloads, or Desktop).
   - Move the **contents** of the folder into `C:\Windows\System32`.

3. **Install the .NET Desktop runtime** from
   [dotnet.microsoft.com](https://dotnet.microsoft.com/en-us/download/dotnet/10.0).

4. **Install DONUT** — the MSI is published under the repo's
   [GitHub Releases](https://github.com/Danial-Changez/DONUT/releases). (Maintainers
   build it from the repo: `pwsh -File tools\Build-Installer.ps1 -Version <x.y.z>` —
   plain `dotnet` is the only prerequisite; the WiX SDK restores itself.)

5. **Add two Defender exclusions**:
   - Open **Virus & threat protection → Manage settings → Add or remove exclusions**.
   - Click **Add an exclusion**, choose **Folder**, and add each of:
     - `C:\Program Files\Bakery\DONUT` — the installed launcher **and the app tree it
       unpacks beside itself and actually runs from**.
     - `C:\ProgramData\DONUT` — the shared data root (config, logs, reports).

:::caution[Why the exclusions?]
DONUT isn't digitally signed (pending an org-sanctioned certificate; the build
script signs automatically once one is provisioned), so Defender may quarantine
it on sight. Both exclusions are scoped to DONUT's own folders.

The first one is also the one that costs you time if you skip it: `Donut.Launcher.exe`
self-extracts its PowerShell tree to an `app\` folder beside the exe and runs from
there, so every launch reads that whole tree. Unexcluded, each file is scanned on
first touch — worst at sign-in, when nothing is cached yet.
:::

:::note[Running from source?]
Neither exclusion covers a dev checkout (`bin\Debug\...\Donut.Launcher.exe`). Add that
folder too if you are testing an unpackaged build and startup feels slow.
:::

## Running from source (developers)

Clone the repo and run — no MSI, exe, or Defender exclusion needed:

```powershell
pwsh -File src\Start-Donut.ps1
```

The script compiles the C# helpers in-process, so it needs nothing beyond
PowerShell 7+. If started from Windows PowerShell 5.1 or an MTA host, it relaunches
itself under `pwsh -Sta` automatically. Add `-Tray` to start hidden in the system
tray (the packaged launcher takes the equivalent `--tray`). Add `-DebugLog` to
force verbose `[DEBUG]` logging for that session (see
[Settings](../features/settings.md#general-section)).

Next: [First launch](./first-launch.md).
