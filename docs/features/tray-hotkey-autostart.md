---
title: Tray, hotkey & autostart
description: The system tray icon, the global show/hide hotkey, and starting with Windows.
---

DONUT is built to live in the background between fleet runs.

## System tray

The tray icon is always present while DONUT runs:

- **Left-click** shows or hides the main window.
- **Right-click** opens the menu (Open / Exit).
- With **Close to tray** enabled in [Settings](./settings.md), the window's X hides
  to the tray instead of exiting (a one-time balloon explains this the first time).

## Global hotkey

The global hotkey (default **`Ctrl+Alt+D`**) shows/restores DONUT from anywhere in
Windows. Record a different combo — or clear it to disable — in
[Settings](./settings.md). If the combo is taken by another app, DONUT warns and
keeps running without it.

:::note
This uses the Win32 `RegisterHotKey` API, **not** a keyboard hook — DONUT never
observes the global keystroke stream.
:::

## Start with Windows

Enabling **Start with Windows (as admin)** registers a per-user scheduled task that
launches DONUT hidden in the tray at logon, already elevated — no UAC prompt each
morning. Turning the toggle off unregisters the task. A second launch of DONUT (from
the Start Menu, say) just surfaces the running instance.

The task always triggers on **your** logon — the account signed in at the console.
What it runs as depends on how DONUT itself is running:

- **DONUT runs as you:** a normal per-user task, elevated, in your own session.
- **DONUT runs as SYSTEM or a separate admin account** — including the common setup
  where you sign in with a standard account and elevate DONUT through UAC with your
  admin account: the task runs as SYSTEM. At logon a small helper
  (`Start-DonutInConsoleSession.ps1`) resolves your console session id *at that
  moment* and hands it to the bundled PsExec, which places DONUT on your desktop.
  The id can't be baked into the task — session ids change every logon, and PsExec's
  `-i` without an id targets the *caller's* session (an invisible session 0), not
  the console.

An RDP-only logon won't surface the tray — injection targets the physical console
session. If the toggle fails, the error toast states the actual reason. Each
firing of the helper is narrated in `%ProgramData%\DONUT\logs\autostart.log`.

:::caution
The autostarted instance runs as `SYSTEM`, but it still uses **your** DONUT data:
at boot it re-points `%LOCALAPPDATA%` at the console user's profile, so settings,
logs, GitHub token and WSID list are shared with your manual runs. (Without this,
the instance read a default config where the toggle is off — and unregistered its
own startup task two minutes in.) One trade-off remains: on the network it
authenticates as the **machine account**, not your admin account, so AD rights can
differ from a manual launch.
:::

These three behaviours map to the `closeToTray`, `globalHotkey`, and
`startWithWindows` keys in the
[config reference](../configuration/config-reference.md), and their design rationale
is covered in the
[architecture overview](../development/architecture/overview.md#tray-autostart-and-global-hotkey).
