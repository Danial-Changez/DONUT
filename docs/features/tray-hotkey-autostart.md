---
title: Tray, hotkey & autostart
description: The system tray icon, the global show/hide hotkey, and starting with Windows.
---

DONUT is built to live in the background between fleet runs.

## System tray

The tray icon is always present while DONUT runs:

- **Left-click** shows or hides the main window.
- **Right-click** opens the menu: Open, Settings, Logs (Explorer on the logs
  folder), Exit.
- With **Close to tray** enabled in [Settings](./settings.md), the window's X hides
  to the tray instead of exiting.

## Global hotkey

The global hotkey (default **`Ctrl+Alt+D`**) shows or restores DONUT from anywhere
in Windows. Record a different combo — or clear it to disable — in
[Settings](./settings.md). If another app already owns the combo, DONUT warns and
keeps running without it.

## Start with Windows

Enabling **Start with Windows** registers a scheduled task that launches DONUT
hidden in the tray when you sign in; turning it off unregisters it. Launching DONUT
again (from the Start Menu, say) just surfaces the running instance.

Turning the toggle on needs administrator rights. If DONUT doesn't have them yet,
it prompts, restarts, and registers the task on the way back — you don't flip the
switch twice.

What you get at sign-in depends on your account:

| Your account | What happens at sign-in |
|---|---|
| Local administrator | DONUT comes up already elevated, with no UAC prompt |
| Standard user | DONUT starts with **limited capability** and says so the first time you open the window. Anything remote then asks for administrator rights; granting it once restarts DONUT elevated for the rest of the session |

:::note
An RDP-only logon won't surface the tray. If the toggle fails, the error toast
states the actual reason.
:::

These behaviours map to the `closeToTray`, `globalHotkey`, `startWithWindows`, and
`runAsAdmin` keys in the
[config reference](../configuration/config-reference.md).
