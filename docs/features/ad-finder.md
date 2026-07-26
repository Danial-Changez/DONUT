---
title: Active Directory finder
description: The search bar's live multi-forest AD search - computers, people, inline account unlock, and temp-password reset.
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
- **Reset a password** — every user row carries a grey **Reset…** utility (Unlock,
  when shown, stays the row's one tinted action) that opens the reset overlay; see
  below.
- **Open a person's Lens** — picking a user opens their [User Lens](./user-lens.md)
  in the detail pane.

## Reset a password

**Reset…** opens a card over the shell (the settings/QR overlay idiom — Esc, the X,
or the backdrop close it) titled with the picked user's name; their UPN and SAM sit in two side-by-side
tiles (the person-fields recipe — the reset still runs against the account's
home domain, it just isn't repeated on the card). The
temporary password is a visible field: type one, or press **Generate** (in the
footer, beside the primary) for a phone-readable `Xxxxx-Xxxxx-99!` (crypto-random;
the pools drop the ambiguous `0/O`, `1/l/I`, `i/o` glyphs and the trailing special
comes from the easily-named `! # $ % + =`, so it survives being read aloud — four
AD complexity classes by construction). **Copy** and **QR** icon buttons sit
beside the field, mirroring the BitLocker key affordances — disabled until a
password exists, and the QR pops the same overlay, on top of the card.

**Require password change at next logon** is pre-checked (Good Defaults: a temp
password should almost always force a change); untick it for the rare exception.
**Reset password** runs `Set-ADAccountPassword -Reset` (plus
`Set-ADUser -ChangePasswordAtLogon`) against the user's home domain on the runspace
pool, and toasts the outcome. Success keeps the card open — you still have to hand
the password over — and closing it is what wipes the secret.

Secrets discipline: the password lives only in the open card (memory), crosses to
the worker as a SecureString, is never written to disk, and never reaches the log —
only sam/domain/flag do. There is no reset entry point on the Lens pane (it lacks
the verified home domain the reset needs); the finder row is the one door.

## How the search works

Each keystroke — debounced, once you've typed at least the minimum prefix — fans out one
LDAP query **per forest** on the runspace pool (computers OR users, prefix match), and
each forest's hits stream into the dropdown as they land. The search runs **in-process**
(unlike the [User Lens](./user-lens.md), which uses the de-elevated agent) — AD reads
don't need de-elevation, and keeping search off the agent means typing never waits on the
agent's startup. Each keystroke supersedes the last; **Esc** dismisses the dropdown.

## Under the hood

![AD finder sequence diagram](/diagrams/ad_finder_sequence_diagram.svg)

*Source: [`ad_finder_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/ad_finder_sequence_diagram.puml)*
