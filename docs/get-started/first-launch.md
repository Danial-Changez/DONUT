---
title: First launch
description: Signing in with the GitHub device flow, the guided tour, and where DONUT keeps its data.
---

## Sign in

Open DONUT from the Start Menu. On first launch (or when the stored token expires),
sign in with your org's GitHub App using the device-code prompt — the code is shown
in the window and copied to your clipboard. This lets the updater pull releases; if
an update is available you'll be prompted to apply it.

## The guided tour

The first time the window opens, a short **guided tour** walks the essentials — the
search bar, the Scan/Apply mode toggle, the machine list, the detail pane, and
Settings. One idea per step:

- **Esc** exits at any point; **Skip Tour** is offered on the welcome step.
- Replay it anytime with the **`?`** button in the title bar; the **book** button beside it
  opens this documentation in your browser.
- It only auto-runs once (tracked by the `hasSeenTour` config key).

## Tray, hotkey, and window basics

- The **tray icon** is always present: left-click it to show or hide the window;
  right-click for Open/Exit.
- The **global hotkey** (default `Ctrl+Alt+D`) shows/restores DONUT from anywhere.
  Change or disable it in [Settings](../features/settings.md).
- Launching DONUT a second time just surfaces the running instance.
- The **version** sits beside the DONUT wordmark. Click it to copy it, which is
  what a bug report needs first.
- **Click a value to copy it** — a hostname, IP, service tag, SAM, UPN, email.
  Dragging still selects part of one.

## Where DONUT keeps its data

Everything user-specific lives under `%ProgramData%\DONUT\data`, so updates and
reinstalls never touch it:

| Folder | Contents |
|--------|----------|
| `config\` | `config.json` (settings) and `recents.json` (the machine list) |
| `logs\` | The central `Donut.log` plus a per-host copy of each run's output log |
| `reports\` | Scan report XMLs |

Next: add machines and [run your first scan](../features/scanning.md).
