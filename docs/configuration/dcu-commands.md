---
title: DCU command reference
description: How the per-command args in config.json become dcu-cli arguments, and what each option does.
---

Each command under `commands` in [config.json](./config-reference.md) carries an
`args` map that DONUT translates into the dcu-cli invocation: boolean `true`
becomes `-silent` / `-reboot=enable`, `false` is omitted (or `=disable` where
explicit), empty strings are omitted, and values with spaces are quoted.

:::tip
If a command runs with none of the dropdown/multi-select options set, DCU uses the
**target machine's** own defaults.
:::

## Options

Based on the
[Dell Command Update CLI reference](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-update-cli-commands):

| Option | Commands | Values | Description |
|--------|----------|--------|-------------|
| `silent` | scan, applyUpdates | (flag) | Hide status/progress on the target |
| `report` | scan | path | XML report location |
| `outputLog` | scan, applyUpdates | path | Log file path |
| `reboot` | applyUpdates | enable/disable | Auto-reboot after updates |
| `autoSuspendBitLocker` | applyUpdates | enable/disable | Suspend BitLocker for BIOS updates |
| `forceupdate` | applyUpdates | enable/disable | Override pause during calls |
| `updateSeverity` | scan, applyUpdates | security,critical,recommended,optional | Filter by severity |
| `updateType` | scan, applyUpdates | bios,firmware,driver,application,others | Filter by type |
| `updateDeviceCategory` | scan, applyUpdates | audio,video,network,storage,input,chipset,others | Filter by category |
| `catalogLocation` | scan, applyUpdates | path | Custom catalog path |

## Return codes

DONUT treats dcu-cli's return code as authoritative and classifies it per command.
Note that `500` is only benign for `scan` — the same code from any other command
is a failure.

| Code | Meaning | DONUT behavior |
|------|---------|----------------|
| `0` | Success | Job completes |
| `1`, `5` | Completed, reboot required / reboot was already pending | Job completes, reboot flagged |
| `500` (scan) | No updates were found | Job completes, no updates listed |
| `501`-`503` | Scan failed (determining updates / canceled / download error) | Job fails; retry |
| `1000`-`1002` | Apply failed (result retrieval / canceled / download error) | Job fails; retry |
| `3`, `7` | Not a Dell system / model not supported | Job fails; do not retry |
| `4` | dcu-cli was not run elevated | Job fails; environment problem on the target |
| `6` | Another DCU instance is running | Job fails; retry after it exits |
| `100`-`113` | Invalid dcu-cli arguments | Job fails; a DONUT bug, report it |
| `3000`-`3005` | Dell Client Management Service not ready (stopped / missing / disabled / busy / updating) | Job fails; retry after the service settles |

The full list is in the
[Dell return-code reference](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes).
