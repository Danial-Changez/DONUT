---
title: Installation
description: What you need before installing, the MSI, and the Defender exclusions.
---

## Before you start

- **Windows admin access on your fleet targets.** Every remote operation
  authenticates as the DONUT process, so it needs an account with administrative
  rights on the machines you manage. DONUT opens without elevation and asks for it
  when you run something remote.
- **Dell Command Update (`dcu-cli.exe`) on each target machine.** This is what
  DONUT drives remotely; it is not needed on your own machine.
- **GitHub App access**, so your team can sign in and receive updates.

Everything else DONUT needs on *your* machine (PsExec, PowerShell 7, and the AD
management tools) installs itself on first launch.

## Install steps

1. **Install DONUT** from the
   [GitHub Releases](https://github.com/Danial-Changez/DONUT/releases) page.

2. **Launch DONUT and approve the prompt.** The installer already fetched PsExec,
   PowerShell 7, and the disk-scan tool. Anything it could not (no network, say)
   is retried the next time you start DONUT as administrator, and DONUT says so.

   :::caution
   The disk-scan tool is [WizTree](https://diskanalyzer.com/), which is free for
   personal use only. Using it in a business needs a purchased licence. The
   automatic download is a convenience, not a licence.
   :::

3. **Add two Defender exclusions:**
   - Open **Virus & threat protection → Manage settings → Add or remove
     exclusions**.
   - Click **Add an exclusion**, choose **Folder**, and add each of:
     - `C:\Program Files\Bakery\DONUT`
     - `C:\ProgramData\DONUT`

:::caution
DONUT isn't digitally signed yet, so Defender may quarantine it or slow every
launch to a crawl. Both exclusions are scoped to DONUT's own folders.
:::

## Testing a beta build

Beta builds are published as prereleases, so the normal install never offers them.
To run one, install it into its own directory from an **elevated** PowerShell:

```powershell
pwsh -File tools\Install-Beta.ps1
```

Run it **as the admin account you elevate DONUT with**. That account ends up owning
the folder and is the only one able to write it. Your everyday signed-in account is
granted read and execute, which is all it needs to launch DONUT.

It takes the newest release, verifies it, unpacks into `C:\Safe\Donut` (override with
`-InstallDir`), sets those permissions, adds a **DONUT (beta)** Start Menu shortcut,
and turns on the [beta channel](../features/self-update.md#beta-channel) so every
later update follows the beta stream and lands in that same directory without
reinstalling anything. Exclude the folder you chose in Defender instead of the
Program Files path above.

A beta install registers nothing with Windows, so it sits **beside** a normal
install rather than replacing it, and uninstalling is deleting the folder. Both
share your settings, machine list and reports, including the beta toggle, so
flipping it applies to whichever copy you open.

Next: [First launch](./first-launch.md).
