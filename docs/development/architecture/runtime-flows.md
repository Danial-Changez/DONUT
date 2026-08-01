---
title: Runtime flows
description: Sequence and activity diagrams tracing DONUT's load-bearing flows end to end.
---

The diagrams below trace the load-bearing flows end to end. Sources are PlantUML
files under [`docs/diagrams/`](https://github.com/Danial-Changez/DONUT/tree/main/docs/diagrams)
in the repo; the SVGs here are rendered from them on every site build.

## Scan a machine (async, non-blocking)

![Scan sequence diagram](/diagrams/scan_sequence_diagram.svg)

*Source: [`scan_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/scan_sequence_diagram.puml)*

## Apply updates (scan reuse + confirm)

![Apply updates sequence diagram](/diagrams/applyUpdates_sequence_diagram.svg)

*Source: [`applyUpdates_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/applyUpdates_sequence_diagram.puml)*

## Remote worker flow (in an isolated child pwsh process)

![Remote worker activity diagram](/diagrams/activity_diagram.svg)

*Source: [`activity_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/activity_diagram.puml)*

## Detail panel: inventory prefetch + storage scan

![Inventory and storage sequence diagram](/diagrams/inventory_sequence_diagram.svg)

*Source: [`inventory_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/inventory_sequence_diagram.puml)*

## Live AD finder + unlock

![AD finder sequence diagram](/diagrams/ad_finder_sequence_diagram.svg)

*Source: [`ad_finder_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/ad_finder_sequence_diagram.puml)*

## User Lens (de-elevated agent)

![Lens lookup sequence diagram](/diagrams/lens_lookup_sequence_diagram.svg)

*Source: [`lens_lookup_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/lens_lookup_sequence_diagram.puml)*

## Remote operation network routing

Resolve → reconnect → update → settle, as a code-grounded trace:

![Network flow diagram](/diagrams/network-flow.svg)

*Source: [`network-flow.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/network-flow.puml)*

## Self-update (device flow + MSI)

![Self-update sequence diagram](/diagrams/update_sequence_diagram.svg)

*Source: [`update_sequence_diagram.puml`](https://github.com/Danial-Changez/DONUT/blob/main/docs/diagrams/update_sequence_diagram.puml)*
