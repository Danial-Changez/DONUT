---
title: User Lens
description: Pick a person to see their directory facts, SCCM devices, and BitLocker recovery keys.
---

Picking a person in the [AD finder](./ad-finder.md) opens their **Lens** in the
detail pane: who they are and what machines they have.

## What it shows

- **Directory facts** — UPN, email, manager, office.
- **Their devices** — the person's SCCM-assigned machines, each on one line of
  model, `Tag <service tag>`, and last domain logon, so a person with three similar
  laptops is tellable apart at a glance. The OS and manufacturer are in the row's
  tooltip. Any device can be **added to the machine list** in one click.
- **BitLocker recovery keys** — revealed on click per device (never shown by
  default), with a QR code for typing-free entry on the target.

Results stream in: person facts first, then device names, then the filled detail.
Each person's results are cached for 15 minutes. If a lookup can't complete, the
pane reports the reason after 90 seconds rather than sitting on its loading
message.

:::note
Lens results reflect **your own** account's permissions in SCCM and AD, not the
administrator account DONUT uses for remote work — so you see exactly what you're
entitled to see.
:::
