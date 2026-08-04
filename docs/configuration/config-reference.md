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
| `throttleLimit` | int, `8` | How many machines run concurrently on the runspace pool |
| `folderScanCount` | int, `12` | How many largest folders the on-demand [storage scan](../features/machine-details.md#storage-scan-biggest-folders) returns (top-N by size) |
| `recoveryWindowMinutes` | int, `30` | After a network drop mid-run, how long DONUT keeps trying to reconnect and resume the log tail before settling the row as *Unconfirmed* |
| `domains` | string[], discovered | The AD domains the [finder](../features/ad-finder.md) searches; each is queried independently. Empty on first run, DONUT discovers them from the machine's forest (every domain in it, child domains included) plus its trust partners and persists the result here. Clear the entry to re-discover |
| `adminServiceHost` | string, discovered | The SCCM AdminService host used by the [User Lens](../features/user-lens.md) device lookup. Empty on first run, DONUT persists the local SCCM client's management point; edit it when the SMS Provider is a different box |
| `startWithWindows` | bool, `false` | Register the logon scheduled task, which starts DONUT as you at your normal rights ([details](../features/tray-hotkey-autostart.md)) |
| `closeToTray` | bool, `false` | The window's X hides to the tray instead of exiting |
| `runAsAdmin` | bool, **`true`** | Elevate DONUT at launch. On by default, and the only key here that falls back to `true` on a missing or corrupt value: remote work authenticates as the process, so a de-elevated DONUT is the console user, who has no rights on fleet targets. Turning it off applies at the next launch; turning it on relaunches through UAC now. **Two things do not follow it:** a tray/autostart launch never elevates (a prompt at the sign-in screen), and a declined prompt never rewrites the key |
| `globalHotkey` | string, `"Ctrl+Alt+D"` | Global show/restore hotkey; blank disables it |
| `openSettingsShortcut` | string, `"Ctrl+,"` | In-app shortcut (while DONUT is focused) that toggles Settings open/closed; blank disables |
| `activeDomainController` | string, discovered | The live domain controller the last DC warm-up picked; read at startup so resolution starts without waiting on AD discovery, rewritten whenever the warm lands on a different DC |
| `hasSeenTour` | bool, `false` | Set once the first-run [guided tour](../get-started/first-launch.md#the-guided-tour) is shown or skipped; the `?` button replays regardless |
| `debugLogging` | bool, `false` | Verbose `[DEBUG]` breadcrumbs in `Donut.log` (job/worker/resolve tracing). INFO/WARN/ERROR always flow; applies live and to every worker child. `Start-Donut -DebugLog` forces it on for one session without persisting |
| `commands` | object | Per-command DCU argument maps — see the [DCU command reference](./dcu-commands.md) |

## Example

```json
{
  "activeCommand": "scan",
  "throttleLimit": 8,
  "folderScanCount": 12,
  "recoveryWindowMinutes": 30,
  "startWithWindows": false,
  "closeToTray": false,
  "runAsAdmin": true,
  "globalHotkey": "Ctrl+Alt+D",
  "openSettingsShortcut": "Ctrl+,",
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

(`domains`, `adminServiceHost` and `activeDomainController` are discovered and
persisted - they are omitted above; override them here if discovery guessed wrong
for your environment.)

## What config.json deliberately does NOT hold

config.json is settings only. Runtime state lives beside it in the data root:

- **Machine list** (`config\recents.json`) - the Home list's per-host entries
  (last run, status, owner, operator-touch recency), capped at 50, written by
  the app as jobs settle. Delete it to reset the list; the `WSID.txt` seed (if
  present) repopulates it on the next launch.
- **Inventory** (`reports\<host>-inventory.json`) and **disk usage**
  (`reports\<host>-folders.csv`) - each probe/scan overwrites its host's file;
  the UI reads these on demand.

Older builds cached all of this inside config.json; the first launch of a
current build migrates the machine list out and drops the rest automatically.
