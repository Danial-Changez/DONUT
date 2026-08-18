---
title: Settings
description: The settings overlay - DCU command options, general app settings, and the keybind recorder. Everything saves in real time.
---

The gear icon opens the settings overlay. There is **no Save button** — every
change persists the moment you make it (text fields when you leave them), and
settings with side effects apply immediately.

## Command sections (Scan / Apply Updates)

Each DCU command has an option form: toggles for flags, chips for the filter lists
(severity, type, device category), and text fields for paths. Every control maps
1:1 to a dcu-cli argument — see the
[DCU command reference](../configuration/dcu-commands.md). Leaving an option empty
lets the target machine's DCU defaults apply.

## General section

| Setting | What it does |
|---|---|
| Start with Windows | Launches DONUT hidden in the tray when you sign in — see [Tray, hotkey & autostart](./tray-hotkey-autostart.md) |
| Close to Tray | The window's X hides to the tray instead of exiting |
| Run as Administrator | On by default. Remote work needs administrator rights, so leave it on. Turning it **on** relaunches through a UAC prompt now, and turning it **off** applies at the next launch. The switch shows what the running process actually is |
| App Hotkey | Shows or restores DONUT from anywhere (default `Ctrl+Alt+D`) |
| Settings Shortcut | Toggles Settings open and closed while DONUT is focused (default `Ctrl+,`) |
| Throttle Limit | How many machines run at once (default 8) |
| Folders to Scan | How many largest folders the storage scan returns (default 12) |
| Automatic Updates | Off by default. On, a newer release installs without asking — a rollback still asks. The update prompt can turn it on too |
| Beta Channel | Off by default. On, the update check also sees prereleases — see [Self-update](./self-update.md#beta-channel) |
| Debug Logging | Verbose breadcrumbs in `Donut.log`, off by default. Applies immediately, no restart |

## Recording a keybind

Keybinds aren't typed — they're **recorded**:

1. Click **Record Keybind**. The field starts listening.
2. Hold your modifier(s) and press one key (e.g. hold `Ctrl+Alt`, tap `D`).
   Releasing the modifiers commits it.
3. **Esc** cancels a recording; **Clear** removes the keybind entirely.

Combos must include `Ctrl`, `Alt`, or `Win` — Shift alone is rejected, since it
would swallow normal typing.

## Where settings live

Everything writes to `config.json` under `%ProgramData%\DONUT\data\config`, which
survives updates and reinstalls. The full key list is in the
[config reference](../configuration/config-reference.md).
