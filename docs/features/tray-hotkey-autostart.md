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
  admin account: the task runs as SYSTEM and relaunches DONUT onto your desktop via
  the bundled PsExec, reproducing the manual launch. DONUT then authenticates on the
  network as the machine account, exactly as those manual runs do.

An RDP logon won't surface the tray — PsExec targets the console session. If the
toggle fails, the error toast states the actual reason.

These three behaviours map to the `closeToTray`, `globalHotkey`, and
`startWithWindows` keys in the
[config reference](../configuration/config-reference.md), and their design rationale
is covered in the
[architecture overview](../development/architecture/overview.md#tray-autostart-and-global-hotkey).
