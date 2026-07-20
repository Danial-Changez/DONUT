---
title: DCU command reference
description: How the per-command args in config.json become dcu-cli arguments, and what each option does.
---

Each command under `commands` in
[config.json](./config-reference.md) carries an `args` map that DONUT translates
into the dcu-cli invocation. `AppConfig.BuildDcuArgs()` generates the
`-option=value` syntax: boolean `true` becomes `-silent` / `-reboot=enable`,
`false` is omitted (or `=disable` where explicit), empty strings are omitted, and
values with spaces are quoted.

> If a command runs with none of the dropdown/multi-select options set, DCU uses the
> **target machine's** own defaults.

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

DONUT treats dcu-cli's return code as authoritative (parsed from the output log):
`0` is the only unconditional success; `1` and `5` mean "completed, reboot
required" (flagged, not an error); everything else is a real failure — including
`2` (unknown), `3` (not a Dell system), `4` (not admin), `6` (another DCU instance
running), and `7`/`8` (unsupported).
