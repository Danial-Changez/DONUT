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
- **Integration (`tests/Integration`):** remote paths (DNS failure, reverse-DNS
  mismatch, RPC 1722) against a mock/loopback target with temp UNC folders to verify
  log/report copy; the ApplyUpdates flow (confirmation/skip, clipboard list); the
  updater flow (SHA-256 verify, HTML/SSO rejection, rollback, hash-gated worker copy).

## Lint and format gates

Before committing:

```powershell
.\tools\Invoke-Format.ps1 -Check   # layout must be clean
.\tools\Invoke-Lint.ps1            # zero non-layout findings
Invoke-Pester -Path tests          # full suite green
```

The analyzer rules live in `PSScriptAnalyzerSettings.psd1`; the conventions they
enforce are described in [Coding style](./coding-style.md).

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
