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
.\tools\Invoke-Tests.ps1           # full suite green (pinned Pester 5)
```

> **Always run the suite through `tools/Invoke-Tests.ps1`, never a bare
> `Invoke-Pester`.** The suite uses Pester 5 syntax; a bare invocation binds to
> whichever Pester wins module resolution. On machines that also carry Windows
> PowerShell's built-in Pester 3.4.0 or a user-scoped Pester 6+, the v3 commands
> can shadow mid-run — after which every remaining test fails with
> `'-Be' is not a valid Should operator` or `The Mock command may only be used
> inside a Describe block`. Those cascades are a tooling artifact, not product
> failures. The runner pins the newest installed Pester 5.5+ and refuses to run
> on any other major version.

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
tests/Generate-CoverageReport.ps1
```

It runs the `tests/Unit` suite, emits `coverage.xml` (JaCoCo format), and converts it
into an HTML report under `CoverageReport/` (open `CoverageReport/index.html`).

The HTML generation is powered by
[JaCoCo-XML-to-HTML-PowerShell](https://github.com/constup/JaCoCo-XML-to-HTML-PowerShell)
by [constup](https://github.com/constup) — coverage reports in pure PowerShell, no
external .NET tools or licenses.
