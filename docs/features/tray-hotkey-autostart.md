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

Enabling **Start with Windows** registers a scheduled task that launches DONUT hidden in
the tray when you sign in. Turning the toggle off unregisters it. A second launch of DONUT
(from the Start Menu, say) just surfaces the running instance.

- The task triggers on **your** logon and runs as **you**, with *Run with highest
  privileges* set.
- **If your account is a local administrator**, DONUT comes up already elevated with no
  UAC prompt at sign-in, which is what the **Run as administrator** toggle defaults to
  wanting. See [Settings](./settings.md#general-section).
- **If it is not**, the task gets your ordinary token instead, and DONUT deliberately does
  **not** elevate itself at sign-in - a prompt on the logon screen is the wrong place to ask
  for credentials. The first time you open the window from the tray it tells you it is
  running with **limited capability**. Anything remote then asks for administrator rights,
  and granting it once restarts DONUT elevated for the rest of the session.
- **Turning this toggle on needs administrator rights itself**, because registering the task
  does. From a de-elevated DONUT it prompts, elevates, and registers the task on the way
  back - you do not have to flip it twice.
- Registering the task itself needs administrator rights, so flipping this switch while
  DONUT is de-elevated prompts to restart elevated first.
- An RDP-only logon won't surface the tray. If the toggle fails, the error toast states
  the actual reason.

:::caution
Older builds started the autostarted instance as `SYSTEM` so it would come up already
elevated. That instance authenticated on the network as the **machine account**, which has
no rights on fleet targets, so it painted a working UI and then failed every scan on access
denied. If you are upgrading, toggle Start with Windows off and on once to replace the old
task; `tools\Diagnose-StartupTask.ps1` reports whether a stale one is still installed.
:::

These behaviours map to the `closeToTray`, `globalHotkey`, `startWithWindows` and
`runAsAdmin` keys in the [config reference](../configuration/config-reference.md), and the
design rationale is in
[Elevation and autostart](../development/architecture/elevation.md).
