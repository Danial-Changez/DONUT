# DONUT Documentation

**Read these docs as a website: <https://danial-changez.github.io/DONUT/>** — built
from this folder by Astro Starlight (`web/`) and deployed on every push to
`main`. For the everyday recipes (edit/add a page, update a diagram) see
[Maintaining this site](development/maintaining-the-site.md).

## Layout

| Path | What it holds |
|------|---------------|
| [index.mdx](index.mdx) | The site's landing page |
| [get-started/](get-started/) | What DONUT is, installation, first launch |
| [features/](features/) | One page per feature: scanning, applying updates, the machine list, details/storage, AD finder, User Lens, tray/hotkey/autostart, self-update, settings |
| [configuration/](configuration/) | The full `config.json` reference and the DCU command/args reference |
| [development/](development/) | Architecture (overview plus one page per subsystem: runspaces and workers, remote execution, AD queries, elevation, User Lens, UI and threading, configuration and persistence, PowerShell constraints; key classes; runtime flows), coding style, testing, UI reference, site maintenance |
| [diagrams/](diagrams/README.md) | PlantUML sources for all diagrams (rendered to SVG at site build; indexed with a mermaid self-update flow that GitHub renders) |
| [plans/](plans/) | Archived implementation plans (historical, not reference) |

Runtime data (logs, reports, config) lives under `%ProgramData%\DONUT\data`, separate
from the `Program Files` install so an MSI upgrade never touches it.
