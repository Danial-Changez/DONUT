---
title: PowerShell constraints
description: Language and packaging constraints the code must keep honoring.
---

PowerShell and WPF constraints that shaped the code. Each of these caused a
shipped regression at least once, so new code must keep honoring them.

- **Absolute script paths in runspaces:** child runspaces must receive absolute
  script paths because `AddScript` rejects relative paths in the packaged build.
- **Window chrome for resize:** XAML `WindowChrome` with
  `AllowsTransparency="False"`, `WindowStyle="None"`, `ResizeMode="CanResize"`,
  and `WindowChrome.ResizeBorderThickness="6"` keeps edge/corner resize without
  any P/Invoke.
- **Every dev-path C# helper guards its own type:** `Start-Donut.ps1` compiles
  the `src/Launcher/*.cs` helpers with `Add-Type` when their types are not
  already resident (production compiles them into `Donut.Launcher`, which also
  hosts this script). Each file must sit behind its **own** `-as [type]` guard
  and compile alone: hiding several helpers behind one guard type crashed
  startup with "Unable to find type [WindowChromeHelper]" - a session with the
  MVVM types resident skipped the whole block, and the class-graph parse died on
  the first missing type. Per-file guards compile exactly what is missing and
  never recompile a resident type (a duplicate would make the name ambiguous
  across assemblies). `StartupDevPath.Tests.ps1` enforces the rule.
- **Locals must not shadow class properties:** inside a PS class method, a local
  variable whose name matches a property (case-insensitive) breaks assignment
  ("Cannot assign property, use '$this.X'"). Pick a different local name (see
  `PersonLens.FromHashtable`'s `$devList` and `LogLine.FromWorkerLine`'s `$ts`).
- **Class methods are statically checked for unassigned variables:**
  `ClassVariableCoverage.Tests.ps1` walks every method's AST because the runtime
  only raises the error when the method actually runs.
- **No live hashtable crosses the runspace boundary:** worker `Settings`/`Options`
  are deep-cloned on the UI thread at prep time (`RemoteServices.BuildWorkerArgs`);
  `AppConfig.DeepClone` is cycle-guarded.
