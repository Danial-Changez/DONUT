---
title: Testing & coverage
description: The dependency-injection testing approach, what each layer tests, and how to generate the coverage report.
---

The core principle is **dependency injection**: a class whose only job is to touch the
network or file system is wrapped so tests can substitute a fake.

```powershell
# Wrapper (src/Core/NetworkProbe.psm1) — the only thing that touches the network
class NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.Dns]::GetHostAddresses($hostname)[0]
    }
}

# Service takes the probe in its constructor
class RemoteJobService {
    hidden $NetworkProbe
    RemoteJobService($probe) { $this.NetworkProbe = $probe }
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
| **Models** | Properties, simple validation, pure mappers/parsers | No mocking needed |
| **Services** | Logic, error handling, orchestration | Mock `NetworkProbe`, file system, PsExec wrapper |
| **Presenters** | UI flow (did clicking Scan call the service?) | Fake the service + a duck-typed `$Home` back-ref |
| **Core** | The actual .NET/exe calls | Don't unit test — use Integration tests |

- **Unit (`tests/Unit`):** config parse/build, service logic with mocks (scan/apply
  two-phase, driver matching, confirmation triggers), self-update token/decision logic,
  the presenter coordinators (e.g. `InventoryPresenter.Tests.ps1`,
  `ResolutionCoordinator.Tests.ps1`) with faked services and a duck-typed `$Home`
  back-ref.
- **Static guards (`tests/Unit`, AST/text-level so they run everywhere):** whole-`src`
  sweeps for mistakes that only surface at runtime on Windows — a class method reading
  a variable it never assigns (`ClassVariableCoverage`), an `AsyncJob` built without a
  logger (`AsyncJobLoggerCoverage`), a `[ProjectClass]::` used without importing its
  module (`TypeImportCoverage`).
- **Integration (`tests/Integration`):** remote paths (DNS failure, reverse-DNS
  mismatch, RPC 1722) against a mock/loopback target with temp UNC folders to verify
  log/report copy; the ApplyUpdates flow (confirmation/skip, clipboard list); the
  updater flow (SHA-256 verify, HTML/SSO rejection, rollback, hash-gated worker copy).

## Lint and format gates

Before committing:

```powershell
.\tools\Invoke-Format.ps1 -Check   # layout must be clean
.\tools\Invoke-Lint.ps1            # zero non-layout findings
.\tools\Invoke-Tests.ps1           # full suite green (pinned Pester 6)
```

> **Always run the suite through `tools/Invoke-Tests.ps1`, never a bare
> `Invoke-Pester`.** A bare invocation binds to whichever Pester wins module
> resolution. On machines that also carry Windows PowerShell's built-in
> Pester 3.4.0 or a leftover user-scoped Pester 5, the older commands can
> shadow mid-run, after which every remaining test fails with
> `'-Be' is not a valid Should operator` or `The Mock command may only be used
> inside a Describe block`. Those cascades are a tooling artifact, not product
> failures. The runner pins the newest installed Pester 6 and refuses to run
> on any other major version.

- `tools/Invoke-Tests.ps1 -FailFast` stops the whole run at the first failing
  test (`Run.SkipRemainingOnFailure`). Use it for a tight fix-and-rerun loop;
  leave it off for CI and pre-push runs so every failure is visible.
- **Stale classes:** `using module` never reloads a module the session already
  imported, so a session that ran the suite before a `git pull` or edit would
  keep testing the old classes from memory. The runner detects repo modules in
  the session and relaunches itself in a clean child `pwsh` automatically; the
  same applies to any ad-hoc snippet that touches product classes - run those
  via `pwsh -NoProfile -File` rather than pasting into a long-lived terminal.

## Assertions

- New tests: prefer Pester 6's type-aware `Should-*` family (`Should-Be`,
  `Should-Throw`, `Should-BeEquivalent` for deep object comparison). Clearer
  failure messages, and input-shape mistakes surface as errors instead of
  passing silently.
- Existing tests: the classic `Should -Be` syntax is fully supported in
  Pester 6. Leave existing assertions as they are; never set
  `Should.DisableV5`.

The analyzer rules live in `PSScriptAnalyzerSettings.psd1`; the conventions they
enforce are described in [Coding style](./coding-style.md).

## Wedge stack probe (field diagnostics)

When a warm or resolve wedges on a real machine, `Donut.log`'s barrier forensics
say *which* shell is stuck; `tools/Get-DonutRunspaceStacks.ps1` says *where*:

```powershell
pwsh -File tools\Get-DonutRunspaceStacks.ps1 -ProcessId <donut pwsh PID>
```

It attaches over PowerShell's built-in named-pipe IPC (same user, nothing to
install), requests a debugger break in every busy runspace, and prints each
script call stack. A runspace that never breaks is wedged inside a single
native/.NET call — that verdict is itself the diagnostic (hooked socket, AMSI
scan, loader lock). An attach timeout means the whole engine is unresponsive
(process-wide loader wedge); exit code 2 flags it. Breaks pause a runspace for
at most `-TimeoutSec`, then `Disable-RunspaceDebug` resumes it — read the log
forensics first, probe second, `dotnet-stack report` only if native stacks are
needed.

## Headless diagnostic runs and the empirical bisect protocol

`tools/Invoke-DiagnosticRun.ps1` runs the app's startup pool sequence without
the UI — N concurrent warm passes behind one barrier deadline (the WarmPool
recipe), DC discovery, then optionally a real resolve and disk scan — and
bundles every signal into one zip: per-phase verdict JSON (rewritten after
every phase, so even a killed run reports), the run's own `Donut.log`,
provenance (commit, pwsh, Defender/AMSI signature version + age), PowerShell
script-block/module events for the run window (enabled per-process via
`-SettingsFile`, no machine policy touched), and — when the barrier lapses —
live runspace stacks captured by the wedge probe while the stuck shells are
still running.

Run it from an **elevated** pwsh (remote work needs an admin token; the pool's Kerberos /
DCOM / AMSI context differs under an admin token):

```powershell
# Full pipeline; send/upload the zip it prints last:
pwsh -File tools\Invoke-DiagnosticRun.ps1 -TargetHost <host> -IncludeDiskScan
```

Everything the diagnostics need stays **under the repo**: `.gitignore` excludes
`.diag/`, so bisect worktrees and output bundles live there without polluting
`git status`. The harness imports nothing from `src/`, so pointing `-SourceRoot`
at another checkout runs that checkout's worker under this harness. Protocol
when a regression has no obvious first-bad commit:

1. **Split code vs. environment first.** Check the suspected-good commits out as
   worktrees under `.diag/` and run the in-tree harness against each *today*:
   ```powershell
   git worktree add .diag\wt\64dbec8 64dbec8
   git worktree add .diag\wt\9304ab3 9304ab3
   pwsh -File tools\Invoke-DiagnosticRun.ps1 -SourceRoot .diag\wt\64dbec8\src -TargetHost <host> -OutDir .diag\out\64dbec8
   pwsh -File tools\Invoke-DiagnosticRun.ps1 -SourceRoot .diag\wt\9304ab3\src -TargetHost <host> -OutDir .diag\out\9304ab3
   pwsh -File tools\Invoke-DiagnosticRun.ps1 -SourceRoot .\src               -TargetHost <host> -OutDir .diag\out\HEAD
   ```
   A historically-good commit failing today means the machine changed, not the
   code — diff the runs' `provenance.json` Defender signature dates and pwsh
   versions. Clean up with `git worktree remove .diag\wt\<sha>` when done.
2. **Bisect each symptom separately** — different symptoms can have different
   first-bad commits. `git bisect` rewrites the working tree, so the predicate
   script must survive checkouts: keep a copy in `.diag/` (untracked, so
   `git checkout` never touches it):
   ```powershell
   Copy-Item tools\Invoke-DiagnosticRun.ps1, tools\Get-DonutRunspaceStacks.ps1 .diag\
   git bisect start <bad> <good>
   git bisect run pwsh -NoProfile -File .diag\Invoke-DiagnosticRun.ps1 `
       -SourceRoot .\src -SkipEventLog -BisectExitCodes [-TargetHost <host>]
   ```
   `-BisectExitCodes` maps pass→0, symptom→1, harness-broken→125
   (`git bisect skip`, for mid-refactor commits that cannot run standalone).
   Bisect the warm symptom with no target host (warm+DC phases only) and the
   resolve symptom with `-TargetHost`.
3. **Full-app checkout runs stay hermetic.** The harness never touches the data
   root, but *launching the app* from an old checkout re-saves the shared config.
   Back it up first and restore after:
   ```powershell
   Copy-Item $env:ProgramData\DONUT\data\config\config.json .diag\config.bak.json
   Copy-Item .diag\config.bak.json $env:ProgramData\DONUT\data\config\config.json
   ```

## Code coverage

Generate a visual HTML coverage report from the project root:

```powershell
tools/Generate-CoverageReport.ps1                     # JaCoCo XML (default)
tools/Generate-CoverageReport.ps1 -Format Cobertura   # Cobertura XML instead
```

What it does:

- Runs the full suite (`tests/`) on the pinned Pester 6 with Pester's
  [built-in code coverage](https://pester.dev/docs/usage/code-coverage) enabled.
- Collects coverage with Pester 6's profiler-based tracer (the default engine,
  much faster than the old breakpoint collector). If coverage numbers ever look
  wrong, set `CodeCoverage.UseBreakpoints = $true` to compare against the
  breakpoint collector.
- Emits `coverage.xml` at the repo root, in JaCoCo or Cobertura format per
  `-Format` (both render identically; pick what a downstream consumer expects).
  Coverage is measured over `src/Core`, `src/Models`, and `src/Services`.
- Renders the XML into an HTML site under `CoverageReport/` with
  [ReportGenerator](https://github.com/danielpalme/ReportGenerator); open
  `CoverageReport/index.html`.

How ReportGenerator is resolved:

- A `reportgenerator` already on `PATH` is used as-is.
- Otherwise the script installs it once as a repo-local dotnet tool under
  `tools/.cache/reportgenerator` (gitignored). This needs the .NET SDK; without
  it the script fails with install guidance instead of a broken report.
