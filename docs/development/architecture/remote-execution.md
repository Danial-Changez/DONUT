---
title: Remote execution
description: The PsExec transport - encapsulation, dcu-cli invocation, per-command return-code classification, and drop recovery.
---

How DONUT reaches a target machine: `PsExec` over SMB (port 445) is the primary
execution engine over native PowerShell Remoting — no WinRM/TrustedHosts
configuration, and native `SYSTEM` execution.

![Remote execution class diagram](/diagrams/class_remote_exec.svg)

*Source: [`class_remote_exec.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_remote_exec.puml)*

## Transport

- **Encapsulation:** `ExecutionService` wraps the PsExec calls; `NetworkProbe`
  handles the pre-run checks (DNS, RPC), isolating network logic from execution.
- **PsExec arguments:** `-s` (SYSTEM), `-h` (elevated), `-accepteula`, with
  `pwsh -NoProfile -NonInteractive -EncodedCommand` (base64 sidesteps psexec
  quoting hazards).
- **Pass the session id explicitly.** `-i` defaults to the caller's session, not
  the console — field-verified against the docs
  ([details](../decisions.md#psexec--i-defaults-to-the-callers-session)).
- **Headless launch:** psexec starts through `ProcessStartInfo` with
  `CreateNoWindow` (a hidden console), never `Start-Process -NoNewWindow` (which
  spawns a visible console per psexec). Its stdout is **not** redirected —
  redirecting removed the console and caused remote `0xC0000142` init failures.
  `ExecutionService.StartPsExecHidden` is the shared launcher.
- **One `-r` service name per job family** (DonutDcu / DonutDisk / DonutProbe /
  DonutDelete): concurrent psexec sessions sharing one PSEXESVC hang when the
  first ends and deletes the service.
- **Every share/WMI touch is gated by a bounded port probe first** (RPC 135 for
  psexec/CIM, SMB 445 for admin-share I/O) — UNC and CIM operations have no usable
  timeout. The psexec path does no controller-side UNC before launch: dcu-cli
  discovery and the pre-run log clear run on the target
  (`BuildRemoteDcuScript`), and a missing dcu-cli comes back as the sentinel exit
  2600, not a hung path.

## Running dcu-cli

- **CLI syntax:** `dcu-cli.exe /<command> -option=value`; booleans as `-silent` or
  `-reboot=enable`. The remote work dir is `C:\temp\DONUT`.
- **Remote file handling:** UNC copy of the remote `outputLog` and `report` files,
  per-host temp logs, report-XML consolidation; the `DellCommandUpdate` service is
  pre-stopped before running DCU.
- Live progress rides dcu-cli's `-outputLog`, tailed over the admin share; the
  remote log is cleared before each run so a recovered code is always this run's.

## Return codes

dcu-cli's return code is authoritative, classified per command by `DcuLog.Classify`
at both gates (the live exit code and the recovered one):

- `0` succeeds everywhere; `1`/`5` mean "completed, reboot required" (flagged, not
  an error).
- `500` from a **scan** is a clean no-updates result: the report copy is skipped
  and the stale local `<host>-Updates.xml` is deleted so a previous run cannot
  re-render.
- Everything else throws `RemoteExecutionException` with the decoded meaning. The
  full table is in the
  [DCU command reference](../../configuration/dcu-commands.md#return-codes).

## Connection-drop recovery

psexec exit codes are classified in layers:

1. Negative = Windows process-launch fault (NTSTATUS), decoded by
   `RemoteProcessStartException`.
2. Win32 transport codes = the connection dropped mid-command, at either end.
3. Everything else is dcu-cli's own code, classified per command as above.

On a drop the run does **not** fail: dcu-cli keeps going on the target, so
`RecoverByResumeTail` reconnects (waiting out a local outage too), resumes the
outputLog tail from the last-seen offset, and recovers the authoritative
`return code: N` line — bounded by `AppConfig.GetRecoveryWindowMinutes`, after
which the run settles Unconfirmed.

## Scan launch/wait breadcrumbs

A Scan that "runs forever" is bounded (`WaitForRemoteProcess` kills + throws at
30 min) and SMB-gated, so the wedge is inside the silent launch-to-wait segment.
Read the breadcrumbs together:

- `RunScanPhase` brackets the launch: `Scan: psexec launch start` /
  `... done in N ms (exit C)`.
- `WaitForRemoteProcess` emits a 30 s heartbeat.
- The scan tick logs `DCU /scan tail: +N log chars in last ~30 s (... SMB
  reachable=B)`.

A `start` with no heartbeats means it never launched; heartbeats with `tail +0
chars` while `reachable=True` mean dcu-cli is running but writing nothing (the
wedge to chase); `tail +N` means it is progressing, just slow.
