# src/Tools

Third-party binaries DONUT bundles (deployed to remote machines or used locally).

## psexec.exe (Sysinternals PsTools)

Drop `psexec.exe` (or `PsExec64.exe`) into this folder to bundle it. Used two ways:

- **Remote execution** (scans, applies, WizTree deploys) — workers currently invoke
  `psexec.exe` from `PATH`.
- **Start-with-Windows under a SYSTEM token** — `StartupTaskService.FindPsExec`
  resolves the SYSTEM-lane task action from this folder **first**, then `PATH`, and
  bakes the absolute path into the task (SYSTEM's logon `PATH` may not have it).

Like `wiztree64.exe`, it embeds into `Donut.Launcher.exe` only if it is present here
**at build time**, and extracts to `%ProgramData%\DONUT\app\src\Tools\`. Absent that,
`FindPsExec` falls back to `PATH` (the installation guide puts PsTools in
`System32`).

## wiztree64.exe (required for "Find big folders")

The **Find big folders** action on a machine's detail panel deploys this binary to
the target's `C:\temp\DONUT\`, runs a fast MFT scan of `C:` as SYSTEM via PsExec,
and copies the resulting `folders.csv` back to parse the largest folders.

**You must drop `wiztree64.exe` into this folder** — it is not downloaded
automatically. Get the standalone 64-bit build from <https://wiztree.com>.

- Expected path: `src/Tools/wiztree64.exe`
- The worker (`ExecutionService.DeployWizTree`) resolves it relative to `SourceRoot`,
  so it must exist here wherever the app runs. If it's missing, the scan fails with a
  clear "Bundled wiztree64.exe not found" message and nothing else is affected.

### How it's invoked (headless)

```
wiztree64.exe "C:" /export="C:\temp\DONUT\folders.csv" /admin=1 ^
  /exportfolders=1 /exportfiles=0 /sortby=1 /exportmaxdepth=4
```

`/admin=1` is the fast MFT scan; with `/export` WizTree scans and self-exits. The
exact command lives in `ExecutionService.BuildScanCommand` so it can be swapped for a
pure-PowerShell folder walk if session-0 (non-interactive SYSTEM) invocation proves
unreliable on a given machine.
