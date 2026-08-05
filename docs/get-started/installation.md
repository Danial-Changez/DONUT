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

Everything else DONUT needs on *your* machine — PsExec, PowerShell 7, and the AD
management tools — installs itself on first launch.

## Install steps

1. **Install DONUT** from the
   [GitHub Releases](https://github.com/Danial-Changez/DONUT/releases) page.

2. **Launch DONUT and approve the prompt.** The first run sets up your machine:
   it installs PsExec, PowerShell 7, the RSAT Active Directory tools, and the
   disk-scan tool if they're missing. This needs administrator rights and takes a
   minute or two. Anything that fails is retried the next time you start DONUT as
   administrator.

   :::caution
   The disk-scan tool is [WizTree](https://diskanalyzer.com/), which is free for
   personal use only. Using it in a business needs a purchased licence — the
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

Next: [First launch](./first-launch.md).
