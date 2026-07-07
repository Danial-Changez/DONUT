# DONUT Documentation

Developer documentation for DONUT. For install/usage, see the
[root README](../README.md).

| Doc | What it covers |
|-----|----------------|
| [Architecture.md](Architecture.md) | How DONUT is built: directory structure, the MVVM layering, the Models/Core/Services/ViewModels/Presenters reference, runtime flows, and the implementation notes (runspaces, PsExec, the de-elevated Lens, threading, config, testing) |
| [Coding-Style.md](Coding-Style.md) | Comment and layout conventions (PowerShell + C#), adapted from the Zephyr style, and the automated lint/format rules |
| [diagrams/](diagrams/README.md) | PlantUML sources for the class/component structure and the per-flow sequence diagrams (indexed, with the self-update flow inlined as mermaid) |

Runtime data (logs, reports, config) lives under `%LOCALAPPDATA%\DONUT`, separate from
the `Program Files` install so an MSI upgrade never touches it.
