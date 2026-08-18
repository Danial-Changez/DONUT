---
title: config.json reference
description: Every key in DONUT's config.json - types, defaults, and what each one controls.
---

DONUT's configuration lives at `%ProgramData%\DONUT\data\config\config.json`. It
persists across updates and reinstalls (the MSI never touches the data root).
User settings are merged over `[AppConfig]::Defaults`, so every expected key always
exists — you only ever see (and edit) real keys.

Most keys are managed through the [Settings overlay](../features/settings.md) and
save in real time; editing the file by hand also works (restart DONUT to pick it
up).

## Keys

| Key | Type / default | What it controls |
|-----|----------------|------------------|
| `activeCommand` | string, `"scan"` | The mode the pill starts on: `scan` or `applyUpdates` |
| `throttleLimit` | int, `8` | How many machines run concurrently |
| `folderScanCount` | int, `12` | How many largest folders the on-demand [storage scan](../features/machine-details.md#storage-scan-biggest-folders) returns (top-N by size) |
| `recoveryWindowMinutes` | int, `30` | After a network drop mid-run, how long DONUT keeps trying to reconnect and resume the log tail before settling the row as *Unconfirmed* |
| `domains` | string[], discovered | The AD domains the [finder](../features/ad-finder.md) searches. Discovered on first run from your forest and its trust partners; clear the entry to re-discover |
| `adminServiceHost` | string, discovered | The SCCM AdminService host the [User Lens](../features/user-lens.md) queries. Discovered on first run; edit it when the SMS Provider is a different box |
| `startWithWindows` | bool, `false` | Register the logon scheduled task, which starts DONUT as you at your normal rights ([details](../features/tray-hotkey-autostart.md)) |
| `closeToTray` | bool, `false` | The window's X hides to the tray instead of exiting |
| `runAsAdmin` | bool, **`true`** | Elevate DONUT at launch — remote work needs it. Turning it off applies at the next launch; turning it on relaunches through UAC now. Two exceptions: a tray/autostart launch never elevates, and a declined prompt never rewrites the key |
| `globalHotkey` | string, `"Ctrl+Alt+D"` | Global show/restore hotkey; blank disables it |
| `openSettingsShortcut` | string, `"Ctrl+,"` | In-app shortcut (while DONUT is focused) that toggles Settings open/closed; blank disables |
| `activeDomainController` | string, discovered | The domain controller DONUT resolves names against; rewritten whenever it picks a different one |
| `hasSeenTour` | bool, `false` | Set once the first-run [guided tour](../get-started/first-launch.md#the-guided-tour) is shown or skipped; the `?` button replays regardless |
| `betaUpdates` | bool, `false` | Follow the [beta channel](../features/self-update.md#beta-channel): the update check also sees prereleases. Off again offers the stable build as a rollback. Machine-wide, so it wins for every copy installed on the machine |
| `autoUpdate` | bool, `false` | Install a newer release without prompting. A rollback always prompts. Also set by the checkbox on the update prompt itself |
| `debugLogging` | bool, `false` | Verbose `[DEBUG]` breadcrumbs in `Donut.log`. Warnings and errors always log; this applies live, no restart |
| `commands` | object | Per-command DCU argument maps — see the [DCU command reference](./dcu-commands.md) |

## Example

```json
{
  "activeCommand": "scan",
  "throttleLimit": 8,
  "folderScanCount": 12,
  "runAsAdmin": true,
  "globalHotkey": "Ctrl+Alt+D",
  "commands": {
    "scan": {
      "args": { "silent": false, "updateSeverity": "", "catalogLocation": "" }
    },
    "applyUpdates": {
      "args": { "silent": false, "reboot": false, "autoSuspendBitLocker": true }
    }
  }
}
```

Discovered keys (`domains`, `adminServiceHost`, `activeDomainController`) are
omitted above — add them only to override a wrong guess.

## What config.json does not hold

config.json is settings only. Runtime state lives beside it in the data root:

| File | Holds |
|---|---|
| `config\recents.json` | The machine list's per-host entries. Delete it to reset the list |
| `reports\<host>-inventory.json` | The last inventory probe for that host |
| `reports\<host>-folders.csv` | The last storage scan for that host |
