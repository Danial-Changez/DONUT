---
title: Testing & coverage
description: The dependency-injection testing approach, what each layer tests, the field-diagnostic tools, and the coverage report.
---

The core principle is **dependency injection**: a class whose only job is to touch
the network or file system is wrapped so tests can substitute a fake.

```powershell
# Wrapper (src/Core/NetworkProbe.psm1), the only thing that touches the network
class NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.Dns]::GetHostAddresses($hostname)[0]
    }
}

# Test substitutes a mock
class MockNetworkProbe : NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.IPAddress]::Parse("192.168.1.100")
    }
}
```

| Component | What to test | How to mock |
| :--- | :--- | :--- |
| **Models** | Properties, validation, pure mappers/parsers | No mocking needed |
| **Services** | Logic, error handling, orchestration | Mock `NetworkProbe`, file system, PsExec wrapper |
| **Presenters** | UI flow (did clicking Scan call the service?) | Fake the service + a duck-typed `$Home` back-ref |
| **Core** | The actual .NET/exe calls | Don't unit test; use Integration tests |

- **Unit (`tests/Unit`):** config parse/build, service logic with mocks,
  self-update decision logic, the presenter coordinators with faked services.
- **Static guards (`tests/Unit`):** whole-`src` AST/text sweeps for mistakes that
  only surface at runtime on Windows: unassigned class variables
  (`ClassVariableCoverage`), logger-less `AsyncJob`s (`AsyncJobLoggerCoverage`),
  un-imported `[ProjectClass]::` uses (`TypeImportCoverage`).
- **Integration (`tests/Integration`):** the real child-process worker transport,
  the warm-pool barrier against a real pool, the real `LensAgent.ps1` serving the
  encrypted exchange end to end, WPF resource/view composition (STA), config and
  recents persistence through a redirected data root, and the pending-intent
  elevation handover. Remote-target legs (psexec, dcu-cli, SMB) run only in the
  manual lab harness (`tools/Invoke-DiagnosticRun.ps1`), never in the suite.

## Lint, format, and test gates

Before committing:

```powershell
.\tools\Invoke-Format.ps1 -Check        # layout must be clean (src, tests, tools)
.\tools\Invoke-Lint.ps1 -FailOn Warning  # what CI gates on: zero Warning-or-worse findings
.\tools\Invoke-Tests.ps1                 # full suite green (pinned Pester 6)
```

:::caution
Always run the suite through `tools/Invoke-Tests.ps1`, never a bare
`Invoke-Pester`: an older Pester (built-in 3.4.0, leftover 5) can shadow mid-run
and fail every remaining test with bogus operator errors. The runner pins Pester 6.
:::

- `-FailFast` stops at the first failing test. Use it for a tight fix-and-rerun
  loop; leave it off for CI so every failure is visible.
- **Stale classes:** `using module` never reloads an already-imported module, so a
  session that ran the suite before an edit keeps testing old classes from memory.
  The runner detects this and relaunches itself in a clean child `pwsh`; run
  ad-hoc snippets via `pwsh -NoProfile -File` for the same reason.

## Assertions

New tests prefer Pester 6's type-aware `Should-*` family (`Should-Be`,
`Should-Throw`, `Should-BeEquivalent`): clearer failures, and input-shape mistakes
surface as errors. Existing `Should -Be` assertions stay as they are; never set
`Should.DisableV5`. Analyzer rules live in `PSScriptAnalyzerSettings.psd1`; the
conventions are in [Coding style](./coding-style.md).

## Wedge stack probe (field diagnostics)

When a warm or resolve wedges, `Donut.log`'s barrier forensics say *which* shell is
stuck; `tools/Get-DonutRunspaceStacks.ps1` says *where*:

```powershell
pwsh -File tools\Get-DonutRunspaceStacks.ps1 -ProcessId <donut pwsh PID>
```

It attaches over PowerShell's named-pipe IPC, breaks every busy runspace, and
prints each script call stack. A runspace that never breaks is wedged inside a
single native/.NET call, and that verdict is itself the diagnostic. An attach timeout
(exit 2) means the whole engine is unresponsive. Read the log forensics first,
probe second, `dotnet-stack report` only if native stacks are needed.

## Headless diagnostic runs and the bisect protocol

`tools/Invoke-DiagnosticRun.ps1` runs the startup pool sequence without the UI
(warm passes behind the barrier, DC discovery, optionally a real resolve and disk
scan) and bundles every signal into one zip (per-phase verdict JSON, the run's
`Donut.log`, provenance incl. Defender signature age, script-block events, and
live runspace stacks when the barrier lapses). Run it from an **elevated** pwsh:

```powershell
pwsh -File tools\Invoke-DiagnosticRun.ps1 -TargetHost <host> -IncludeDiskScan
```

`.gitignore` excludes `.diag/`, so worktrees and bundles live there. The harness
imports nothing from `src/`, so `-SourceRoot` can point at any checkout. When a
regression has no obvious first-bad commit:

1. **Split code vs. environment.** Run the harness against known-good commits as
   worktrees *today*:
   ```powershell
   git worktree add .diag\wt\<sha> <sha>
   pwsh -File tools\Invoke-DiagnosticRun.ps1 -SourceRoot .diag\wt\<sha>\src -TargetHost <host> -OutDir .diag\out\<sha>
   ```
   A historically-good commit failing today means the machine changed, not the
   code; diff the runs' `provenance.json`.
2. **Bisect each symptom separately.** `git bisect` rewrites the working tree, so
   keep the predicate script in `.diag/` (untracked):
   ```powershell
   Copy-Item tools\Invoke-DiagnosticRun.ps1, tools\Get-DonutRunspaceStacks.ps1 .diag\
   git bisect start <bad> <good>
   git bisect run pwsh -NoProfile -File .diag\Invoke-DiagnosticRun.ps1 `
       -SourceRoot .\src -SkipEventLog -BisectExitCodes [-TargetHost <host>]
   ```
   `-BisectExitCodes` maps pass→0, symptom→1, harness-broken→125 (`bisect skip`).
3. **Keep full-app checkout runs hermetic.** Launching the app from an old
   checkout re-saves the shared config, so back up
   `%ProgramData%\DONUT\data\config\config.json` first and restore after.

## Code coverage

```powershell
tools/Invoke-Tests.ps1 -Coverage                     # JaCoCo XML (default)
tools/Invoke-Tests.ps1 -Coverage -Format Cobertura   # Cobertura XML instead
```

Runs the full suite with Pester 6's profiler-based coverage over `src/Core`,
`src/Models`, and `src/Services`, emits `coverage.xml`, and renders an HTML site
under `CoverageReport/` with ReportGenerator. ReportGenerator resolves from `PATH`,
else installs once as a repo-local dotnet tool under
`tools/.cache/reportgenerator`; `REPORTGENERATOR_LICENSE` (read from all env
scopes) unlocks PRO features. If coverage numbers ever look wrong, set
`CodeCoverage.UseBreakpoints = $true` to compare against the breakpoint collector.
