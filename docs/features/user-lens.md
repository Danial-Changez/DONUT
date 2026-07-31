---
title: User Lens
description: Pick a person to see their directory facts, SCCM devices, and BitLocker keys - fetched de-elevated.
---

Picking a person in the [AD finder](./ad-finder.md) opens their **Lens** in the
detail pane: who they are and what machines they have.

## What it shows

- **Directory facts** — UPN, email, manager, office (from AD, forest-wide via the
  Global Catalog).
- **Their devices** — the person's SCCM-assigned machines, each over one line of
  model, `Tag <service tag>` and last domain logon, so a person with three similar
  laptops is tellable apart at a glance. Model and tag come from SCCM hardware
  inventory and drop out (with their separator) when the AdminService cannot serve
  them. The OS and manufacturer are on the row's tooltip. Any device can be
  **added to the machine list** in one click.
- **BitLocker recovery keys** — revealed on click per device (never shown by
  default), with a QR code for typing-free entry on the target.

Results stream progressively: person facts first, then device names, then the filled
detail — so the pane paints while the lookup completes. Lens results are cached in
memory for 15 minutes per person.

A lookup runs on its own runspace lane, so picking a person while a fleet-wide scan is
running works normally. If one still can't complete, the pane reports the reason after
90 seconds rather than sitting on its loading message.

## Why it runs de-elevated

When DONUT is running **elevated as an admin account** (which every remote operation
needs), SCCM's AdminService is RBAC-scoped to your **regular account**, and that goes for
BitLocker keys in AD too. DONUT therefore keeps a small agent running **de-elevated as your
logged-on account** and asks it for the Lens data over an encrypted, ACL-locked exchange.

Running DONUT without administrator rights skips all of that: it is already your account,
so the lookup runs in process. The pane then fills in one step instead of painting
progressively. Details in the
[User Lens architecture page](../development/architecture/user-lens.md).

## Under the hood

![Lens lookup sequence diagram](/diagrams/lens_lookup_sequence_diagram.svg)

*Source: [`lens_lookup_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/lens_lookup_sequence_diagram.puml)*
