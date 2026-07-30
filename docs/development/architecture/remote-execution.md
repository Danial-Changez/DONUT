---
title: Remote execution
description: The PsExec transport - encapsulation, dcu-cli invocation, per-command return-code classification, and drop recovery.
---

How DONUT reaches a target machine: `PsExec` over SMB (port 445) is the primary
execution engine over native PowerShell Remoting - no WinRM/TrustedHosts
configuration, and native `SYSTEM` execution.

![Remote execution class diagram](/diagrams/class_remote_exec.svg)

*Source: [`class_remote_exec.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/class_remote_exec.puml)*

## Transport

- **Encapsulation:** `ExecutionService` wraps the `PsExec` calls; `NetworkProbe`
  handles the pre-run checks (DNS, reverse-DNS, RPC), isolating network logic
  from execution.
- **PsExec arguments:** `-s` (SYSTEM), `-h` (elevated), `-accepteula`, with
  `pwsh -NoProfile -NonInteractive -c` for clean remote execution.
- **`-i` defaults to the caller's session, not the console.** The psexec docs say
  "if no session is specified the process runs in the console session";
  field-verified otherwise (2026-07-27): called from a SYSTEM scheduled task,
  `psexec -s -i -d` landed DONUT in session 0. Always pass the session id
  explicitly - the autostart shim resolves `WTSGetActiveConsoleSessionId()` at
  fire time. **Note:** with `-d`, psexec's exit code is the launched **PID**, so
  a "failed" task result like `10176` is actually success.
- **Headless launch:** psexec is started through `ProcessStartInfo` with
  `CreateNoWindow` (a hidden console), not `Start-Process -NoNewWindow`. DONUT is
  a window-subsystem GUI with no console; `-NoNewWindow` makes the OS spawn a
  visible console per psexec, which reads as a frozen UI. A hidden console leaves
  psexec a real console - so its stdout is **not** redirected (redirecting it
  removed the console and caused remote `0xC0000142` init failures) - with no
  window. `ExecutionService.StartPsExecHidden` is the shared launcher.

## Running dcu-cli

- **CLI syntax:** `dcu-cli.exe /<command> -option=value` (not `/key`); booleans
  as `-silent` or `-reboot=enable`. The remote work dir is `C:\temp\DONUT`.
- **Remote file handling:** UNC copy of the remote `outputLog` and `report`
  files, per-host temp logs, and report-XML consolidation before writing local
  logs; the `DellCommandUpdate` service is pre-stopped before running DCU.
- Live progress rides dcu-cli's `-outputLog`, tailed over the admin share into
  the Information stream while psexec runs; the remote log is cleared before
  each run so a recovered code is always this run's.

## Return codes (per command)

dcu-cli's return code is authoritative and is classified per command by
`DcuLog.Classify`:

- `0` succeeds for any command; `1`/`5` mean "completed, reboot required"
  (flagged on the result, not an error).
- `500` from a **scan** is a clean no-updates result: the job completes, the
  report copy is skipped, and the stale local `<host>-Updates.xml` is deleted so
  a previous run's updates cannot re-render. The artifact carries `DcuCode` and
  `NoUpdatesFound` (mirroring the apply path's `RebootRequired`).
- Everything else throws `RemoteExecutionException` with the decoded meaning
  (`DcuLog.DescribeReturnCode` names the documented codes individually,
  including the 3000-series Dell Client Management Service states).
- Both gates use the classifier: the live exit code in `InvokePsExec` and the
  recovered code from `RecoverByResumeTail` (below).
- The full table is in the [DCU command reference](../../configuration/dcu-commands.md#return-codes).

## Connection-drop recovery

psexec exit codes are classified in layers:

1. Negative = Windows process-launch fault (NTSTATUS), decoded by
   `RemoteProcessStartException`.
2. Win32 transport codes = the connection dropped mid-command, at either end -
   the target's NIC reset (a network driver install) or the operator's own
   laptop lost Wi-Fi.
3. Everything else is dcu-cli's own code, classified per command as above.

On a drop the run does **not** fail: dcu-cli keeps going on the target, so
`RecoverByResumeTail` reconnects (waiting out a local outage too), resumes the
outputLog tail from the last-seen offset, and recovers dcu-cli's authoritative
`return code: N` line - bounded by `AppConfig.GetRecoveryWindowMinutes`, after
which the run settles Unconfirmed.

**Note:** concurrent psexec sessions sharing one PSEXESVC hang when the first
ends and deletes the service, so each job family runs under its own `-r` service
name (DonutDcu / DonutDisk / DonutProbe).

**Note:** UNC and CIM operations have no usable timeout, so every share/WMI touch
is gated by a bounded port probe first (RPC 135 for psexec/CIM, SMB 445 for
admin-share I/O). An OPEN 445 still does not guarantee the C$ share responds, so
the psexec path does no controller-side UNC before launch: dcu-cli discovery and
the pre-run log clear both run on the target (`BuildRemoteDcuScript`), and a
missing dcu-cli comes back as the `$DcuNotFoundExit` sentinel (2600), not a hung
path.

## Scan launch/wait breadcrumbs

A Scan that "runs forever" is bounded (`WaitForRemoteProcess` kills + throws at
30 min) and SMB-gated, so the wedge is inside the silent launch-to-wait segment.
Read the breadcrumbs together:

- `RunScanPhase` brackets the launch with `Scan: psexec launch start` /
  `... done in N ms (exit C)`.
- `WaitForRemoteProcess` emits a 30 s `still waiting after N s (remote process
  running)` heartbeat.
- The scan tick logs `DCU /scan tail: +N log chars in last ~30 s (... SMB
  reachable=B)`.

A `start` with no heartbeats means it never launched; heartbeats with
`tail +0 chars` while `reachable=True` mean dcu-cli is running but writing
nothing (the wedge to chase); `tail +N` means it is progressing, just slow.
