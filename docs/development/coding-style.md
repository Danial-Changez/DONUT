---
title: Coding style
description: Comment and layout conventions for DONUT's PowerShell and C# sources, adapted from the Zephyr style.
---

Comment and layout conventions for the sources under `src/`. The rules are adapted
once from the [Zephyr RTOS coding style](https://docs.zephyrproject.org/latest/contribute/style/code.html)
and [documentation guidelines](https://docs.zephyrproject.org/latest/contribute/documentation/guidelines.html),
translated to PowerShell and C#; where these rules are silent, follow the style of
the surrounding code.

## Comments

**Comments explain *why*, never *what*.** A comment earns its place only by stating
something the code cannot show — a constraint, a hazard, a protocol quirk, or a
decision that would otherwise be re-litigated:

```powershell
# WaitHandle.WaitAll throws on an STA thread, so wait per-handle with WaitOne.
```

Never narrate the next line:

```powershell
# Populate fields          <- delete: the call below says exactly this
$this.PopulateFields()
```

**One line.** Two is the exception, not the target, and only for the comment that
introduces a whole unit:

- A file header, above the `namespace` or the first statement.
- A `class` declaration's own comment.
- In PowerShell, a method or function's doc comment (C# uses `///` there, which is
  exempt from the count because XML doc tags need their own lines).

Anything needing more room is documentation, not a comment: put it in the file's
`.NOTES` block or a page under `docs/`, and reference it inline (`see .NOTES`).
Deleting a comment is always an option — one that only narrates the next line has
no claim to the space.

**No semicolons or dashes as connectors.** Use "and", a comma, or a second
sentence. If a comment genuinely lists things, use a colon and short dashed
entries:

```csharp
// Installs what the machine is missing:
// - PsExec, which every remote operation runs through.
// - PowerShell 7, which worker processes need.
```

A list is exempt from the line limit, but only when it makes the comment *shorter*
than the prose it replaces. It is not a licence to write more.

**Doc comments on the API:**

- Every module and entry script opens with comment-based help: `.SYNOPSIS`,
  `.DESCRIPTION`, and `.NOTES` for cross-cutting constraints.
- Every class and non-trivial public method gets a brief `#` doc comment stating
  its contract — what the signature can't show, never a restatement of the name.
  Trivial getters/setters need none.
- Fields get a short trailing comment only when the type/name doesn't already say
  it (units, ownership, lifetime).

**Layout:**

- Comments wrap at ~90 columns (hard cap 100).
- Sentence case; capitalize acronyms (`DCU`, `SMB`, `UNC`). No all-caps emphasis —
  if a point needs stress, say why instead.
- Plain sentences: no informal jargon ("gotcha", "hack") — name the actual
  constraint.
- ASCII only, and never emojis. Non-ASCII in string literals is a product
  decision, not a style one.
- Section separators, used sparingly: exactly `# --- Section name ---`.

## Code

- No trailing whitespace; spaces around operators.
- Comments inside remote-script here-string templates (e.g.
  `InventoryService::BuildProbeScript`) are part of the shipped payload — edit
  them only deliberately, never in a style sweep.

## C# (`src/Launcher/`)

Same "why, not what" rule, expressed as **XML documentation comments** (`///`),
scoped to the public API:

- **Public types and non-trivial public members** get a `<summary>` stating the
  contract. `<param>`/`<returns>`/`<exception>` only where they carry something the
  signature doesn't; `<remarks>` for cross-cutting notes.
- **Trivial members need none** — leave undocumented rather than restate the name.
- **Internal/private members are not API** — a plain `//` for the why, no `///`.
- **Interface implementations** use `/// <inheritdoc/>`.
- Nullable reference types are on; annotate honestly so the compiler stays quiet.
- WinForms custom controls mark code-only public properties
  `[DesignerSerializationVisibility(Hidden)]` (analyzer WFO1000).
- Section separators: `// --- Section name ---`.

`GenerateDocumentationFile` is intentionally off: the docs are for readers, not a
published API surface, so CS1591 is not a build gate.

## Formatting (automated)

The `Rules` section of `PSScriptAnalyzerSettings.psd1` is the repo's
".clang-format", mapped from Zephyr's:

| Zephyr `.clang-format`        | DONUT equivalent                                        |
| ----------------------------- | ------------------------------------------------------- |
| `ColumnLimit: 100`            | `PSAvoidLongLines` at 100 (reported, not build-breaking) |
| `IndentWidth: 8` (tabs)       | 4-space indent (`PSUseConsistentIndentation`)            |
| `BreakBeforeBraces: Linux`    | Open brace same line; `else`/`catch` on their own line   |
| `AlignConsecutiveMacros`      | Hashtable assignment alignment                           |
| proper capitalization         | `PSUseCorrectCasing`                                     |
| `InsertNewlineAtEndOfFile`    | Enforced by `Invoke-Format.ps1`                          |

```powershell
pwsh -File tools\Invoke-Format.ps1          # fix src\ in place
pwsh -File tools\Invoke-Format.ps1 -Check   # CI / pre-commit gate
```

The VS Code PowerShell extension picks up the same settings file, so **Format
Document** produces identical output.

## Linting

`tools/Invoke-Lint.ps1` runs PSScriptAnalyzer with the repo settings over `src/`,
then sweeps **every** PowerShell and C# file in the repo for the comment-length
rule above. PSScriptAnalyzer has no such rule and cannot parse C# at all, so
nothing else would catch it. Run it (and `Invoke-Format.ps1 -Check`) before
committing; new findings are fixed, not suppressed.

The comment sweep starts clean and gates unconditionally, so any hit is something
you just added. The `Invoke-StyleCheckForChange` hook applies the same rule per
edit, so it usually surfaces before the lint run does.

`PSAvoidLongLines` is report-only: wrap when it's free, but leave a line long when
wrapping would hurt — long URLs, the here-string script templates, and string
literals where a mid-string break reads worse than the overrun.
