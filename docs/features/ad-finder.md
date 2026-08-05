---
title: Active Directory finder
description: The search bar's live multi-forest AD search - computers, people, inline account unlock, and temp-password reset.
---

The search bar doubles as a live Active Directory finder. As you type, DONUT
searches **computers and users** across your org's forests and shows matches in a
dropdown, grouped by kind. Configure which forests are searched with
[`domains`](../configuration/config-reference.md).

Type at least a few characters; each forest's hits appear as they land. **Esc**
dismisses the dropdown.

## What you can do from the dropdown

| Action | How |
|---|---|
| Add a computer | Pick a computer result — it joins the [machine list](./machine-list.md) right away |
| Open a person's Lens | Pick a user result to see their [User Lens](./user-lens.md) in the detail pane |
| Unlock an account | Locked-out users show an **Unlock** button inline — no detour into ADUC |
| Reset a password | Every user row has a **Reset…** button (see below) |

Enter acts on real results only: it picks the top-ranked computer if any matched,
otherwise the top user. Typing a name that matches nothing does nothing on Enter —
to add machines by name, paste a list (see [the machine list](./machine-list.md)).

## Reset a password

1. Click **Reset…** on a user row. A card opens over the shell, titled with that
   person's name and showing their UPN and SAM.
2. Type a temporary password, or click **Generate** for a phone-readable one like
   `Xxxxx-Xxxxx-99!` — ambiguous characters (`0/O`, `1/l/I`) are excluded so it
   survives being read aloud.
3. Use **Copy** or **QR** beside the field to hand it over. Both stay disabled
   until a password exists.
4. Leave **Require Password Change at Next Logon** checked unless you have a
   reason not to, then click **Reset Password**.

Success keeps the card open — you still have to give the password to the person.
Closing the card wipes it.

:::note
The password never touches disk or the log, and the finder row is the only place to
start a reset (the Lens pane lacks the home-domain information the reset needs).
:::
