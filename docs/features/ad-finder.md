---
title: Active Directory finder
description: The search bar's live multi-forest AD search - computers, people, and inline account unlock.
---

The search bar doubles as a live Active Directory finder. As you type, DONUT
searches **computers and users** across the org's forests (configurable via
[`domains`](../configuration/config-reference.md)) and shows matches in a dropdown,
grouped by kind.

## What you can do from the dropdown

- **Add a computer** — picking a computer result adds it to the
  [machine list](./machine-list.md) (and prefetches its IP + inventory).
- **Add typed text as a machine** — the first row offers "Add ‹text› as a machine".
  It's pre-selected when the text looks like a machine name (pattern-matched, or an
  exact AD computer match), so Enter never guesses wrong.
- **Unlock an account** — locked-out users show an **Unlock** action inline; no
  detour into ADUC.
- **Open a person's Lens** — picking a user opens their [User Lens](./user-lens.md)
  in the detail pane.

## How the search works

Each keystroke — debounced, once you've typed at least the minimum prefix — runs one
combined LDAP query per forest (computers OR users, prefix match). The search runs
through the **same persistent de-elevated agent as the [User Lens](./user-lens.md)**:
it keeps its directory connections warm and runs as *your* logged-on account rather than
DONUT's elevated one, so results come back quickly. Each keystroke supersedes the last;
**Esc** dismisses the dropdown.

## Under the hood

![AD finder sequence diagram](/DONUT/diagrams/ad_finder_sequence_diagram.svg)

*Source: [`ad_finder_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/ad_finder_sequence_diagram.puml)*
