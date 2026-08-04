<div align="center">

<img src="assets/Images/logo yellow arrow.png" alt="DONUT" width="96" />

# DONUT

**Dell fleet management, from one window.**

[![CI](https://github.com/Danial-Changez/DONUT/actions/workflows/ci.yml/badge.svg)](https://github.com/Danial-Changez/DONUT/actions/workflows/ci.yml)
[![Docs](https://github.com/Danial-Changez/DONUT/actions/workflows/docs.yml/badge.svg)](https://github.com/Danial-Changez/DONUT/actions/workflows/docs.yml)
[![Release](https://img.shields.io/github/v/release/Danial-Changez/DONUT)](https://github.com/Danial-Changez/DONUT/releases/latest)
[![License](https://img.shields.io/github/license/Danial-Changez/DONUT)](LICENSE)

</div>

DONUT searches Active Directory for machines and people, runs remote driver and
BIOS updates through Dell Command Update in parallel, inspects hardware and
storage per machine, and looks up a user's devices and BitLocker recovery keys —
a WPF app driven by PowerShell classes, shipped as a single self-updating MSI.

## Documentation

Everything lives at **<https://danial-changez.github.io/DONUT/>**, built from
[`docs/`](docs/README.md):

- [What is DONUT?](docs/get-started/what-is-donut.md) — the tour of what it does
- [Installation](docs/get-started/installation.md) and
  [first launch](docs/get-started/first-launch.md)
- [Feature guides](docs/features/) — scanning, applying updates, the AD finder,
  the User Lens, machine details, settings
- [`config.json` reference](docs/configuration/config-reference.md)
- [Architecture](docs/development/architecture/overview.md) and the
  [developer pages](docs/development/testing.md) — how it's built and tested

## Install

Grab `DONUT.msi` from the
[latest release](https://github.com/Danial-Changez/DONUT/releases/latest)
(needs the
[.NET Desktop Runtime 10](https://dotnet.microsoft.com/en-us/download/dotnet/10.0)),
or run straight from source with nothing but PowerShell 7+:

```powershell
pwsh -File src\Start-Donut.ps1
```

The [installation guide](docs/get-started/installation.md) covers target-machine
prerequisites (dcu-cli, PsExec) and the unsigned-MSI Defender note.

## License

[MIT](LICENSE)
