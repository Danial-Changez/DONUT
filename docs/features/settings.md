---
title: Settings
description: The settings overlay - DCU command options, general app settings, and the keybind recorder. Everything saves in real time.
---

The gear icon opens the settings overlay. There is **no Save button** — every change
persists the moment you make it (text fields when you leave them), and settings that
have side effects apply immediately: recording a new hotkey re-registers it,
toggling Start with Windows reconciles the scheduled task.

## Command sections (Scan / Apply Updates)

Each DCU command has an option form: toggles for flags (`silent`, `reboot`,
`autoSuspendBitLocker`, `forceupdate`), chips for the filter lists (severity, type,
device category), and text fields for paths (`outputLog`, `report`,
`catalogLocation`). Every control maps 1:1 to a dcu-cli argument — see the
[DCU command reference](../configuration/dcu-commands.md). Leaving an option empty
lets the target machine's DCU defaults apply.

## General section

- **Start with Windows (as admin)** — registers/unregisters the logon scheduled
  task. See [Tray, hotkey & autostart](./tray-hotkey-autostart.md).
- **Close to tray** — the window's X hides to the tray instead of exiting.
- **Global hotkey** — shows/restores DONUT from anywhere (default `Ctrl+Alt+D`).
- **Settings shortcut** — an in-app shortcut (while DONUT is focused) that toggles Settings
  open and closed (default `Ctrl+,`); Esc also closes.
- **Throttle limit** — how many machines run concurrently (default 8).
- **Folders to scan** — how many largest folders the storage scan returns (default 12).

## Recording a keybind

Keybinds aren't typed — they're **recorded**:

1. Click **Record Keybind**. The field starts listening.
2. Hold your modifier(s) and press one key (e.g. hold `Ctrl+Alt`, tap `D`). The
   preview updates live; releasing the modifiers commits it.
3. **Esc** cancels a recording; **Clear** removes the keybind entirely (disabling
   that shortcut).

Combos must include `Ctrl`, `Alt`, or `Win` (Shift alone is rejected — it would
swallow normal typing).

## Where settings live

Everything writes to `config.json` under `%LOCALAPPDATA%\DONUT\config`, which
survives updates and reinstalls. The full key list is in the
[config reference](../configuration/config-reference.md).
