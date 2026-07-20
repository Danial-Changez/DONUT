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

These three behaviours map to the `closeToTray`, `globalHotkey`, and
`startWithWindows` keys in the
[config reference](../configuration/config-reference.md), and their design rationale
is covered in the
[architecture overview](../development/architecture/overview.md#tray-autostart-and-global-hotkey).
