---
title: config.json reference
description: Every key in DONUT's config.json - types, defaults, and what each one controls.
---

DONUT's configuration lives at `%LOCALAPPDATA%\DONUT\config\config.json`. It
persists across updates and reinstalls (the MSI never touches `%LOCALAPPDATA%`).
User settings are merged over `[AppConfig]::Defaults`, so every expected key always
exists — you only ever see (and edit) real keys.

Most keys are managed through the [Settings overlay](../features/settings.md) and
save in real time; editing the file by hand also works (restart DONUT to pick it
up).

## Keys

| Key | Type / default | What it controls |
|-----|----------------|------------------|
| `activeCommand` | string, `"scan"` | The mode the pill starts on: `scan` or `applyUpdates` |
| `throttleLimit` | int, `8` | How many machines run concurrently on the runspace pool |
| `recoveryWindowMinutes` | int, `30` | After a network drop mid-run, how long DONUT keeps trying to reconnect and resume the log tail before settling the row as *Unconfirmed* |
| `domains` | string[], org forests | The AD forests the [finder](../features/ad-finder.md) searches; each is queried independently |
| `adminServiceHost` | string, org SMS Provider | The SCCM AdminService host used by the [User Lens](../features/user-lens.md) device lookup |
| `startWithWindows` | bool, `false` | Register the elevated logon scheduled task ([details](../features/tray-hotkey-autostart.md)) |
| `closeToTray` | bool, `false` | The window's X hides to the tray instead of exiting |
| `globalHotkey` | string, `"Ctrl+Alt+D"` | Global show/restore hotkey; blank disables it |
| `openSettingsShortcut` | string, `"Ctrl+,"` | In-app shortcut (while DONUT is focused) to open Settings; blank disables |
| `machineNamePatterns` | string[], `^CAP-`, `^B[0-9]{4}`, `^WVD` | Regex patterns that mark search text as a machine name (vs. a person), so the finder pre-selects "Add as a machine". Edit as naming conventions change |
| `hasSeenTour` | bool, `false` | Set once the first-run [guided tour](../get-started/first-launch.md#the-guided-tour) is shown or skipped; the `?` button replays regardless |
| `commands` | object | Per-command DCU argument maps — see the [DCU command reference](./dcu-commands.md) |

## Example

```json
{
  "activeCommand": "scan",
  "throttleLimit": 8,
  "recoveryWindowMinutes": 30,
  "startWithWindows": false,
  "closeToTray": false,
  "globalHotkey": "Ctrl+Alt+D",
  "openSettingsShortcut": "Ctrl+,",
  "machineNamePatterns": ["^CAP-", "^B[0-9]{4}", "^WVD"],
  "hasSeenTour": true,
  "commands": {
    "scan": {
      "args": {
        "silent": false,
        "report": "",
        "outputLog": "",
        "updateSeverity": "",
        "updateType": "",
        "updateDeviceCategory": "",
        "catalogLocation": ""
      }
    },
    "applyUpdates": {
      "args": {
        "silent": false,
        "reboot": false,
        "autoSuspendBitLocker": true,
        "forceupdate": false,
        "outputLog": "",
        "updateSeverity": "",
        "updateType": "",
        "updateDeviceCategory": "",
        "catalogLocation": ""
      }
    }
  }
}
```

(`domains` and `adminServiceHost` default to the org's forests and SMS Provider and
are omitted above; override them in Settings or here if your environment differs.)
