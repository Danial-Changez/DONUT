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
something the code cannot show: a constraint, a hazard, a protocol quirk, or a
decision that would otherwise be re-litigated.

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
Deleting a comment is always an option. One that only narrates the next line has
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
  its contract: what the signature can't show, never a restatement of the name.
  Trivial getters/setters need none.
- Fields get a short trailing comment only when the type/name doesn't already say
  it (units, ownership, lifetime).

**Layout:**

- Comments wrap at ~90 columns (hard cap 100).
- Sentence case; capitalize acronyms (`DCU`, `SMB`, `UNC`). No all-caps emphasis.
  If a point needs stress, say why instead.
- Plain sentences: no informal jargon ("gotcha", "hack"). Name the actual
  constraint.
- ASCII only, and never emojis. Non-ASCII in string literals is a product
  decision, not a style one.
- Section separators, used sparingly: exactly `# --- Section name ---`.

## Code

- No trailing whitespace; spaces around operators.
- Comments inside remote-script here-string templates (e.g.
  `InventoryService::BuildProbeScript`) are part of the shipped payload. Edit
  them only deliberately, never in a style sweep.

## C# (`src/Launcher/`)

Same "why, not what" rule, expressed as **XML documentation comments** (`///`),
scoped to the public API:

- **Public types and non-trivial public members** get a `<summary>` stating the
  contract. `<param>`/`<returns>`/`<exception>` only where they carry something the
  signature doesn't; `<remarks>` for cross-cutting notes.
- **Trivial members need none.** Leave undocumented rather than restate the name.
- **Internal/private members are not API.** A plain `//` for the why, no `///`.
- **Interface implementations** use `/// <inheritdoc/>`.
- Nullable reference types are on; annotate honestly so the compiler stays quiet.
- WinForms custom controls mark code-only public properties
  `[DesignerSerializationVisibility(Hidden)]` (analyzer WFO1000).
- Section separators: `// --- Section name ---`.

`GenerateDocumentationFile` is intentionally off: the docs are for readers, not a
published API surface, so CS1591 is not a build gate.

Layout follows the same brace style as the PowerShell (1TBS: `if (x) {` and
`} else {` / `} catch {`), declared in the repo's `.editorconfig` and applied by
`dotnet format whitespace src/Launcher/Donut.Launcher.csproj`. A short statement
may share the `if` line (`if (x) return;`), matching clang-tidy's
`braces-around-statements` with `ShortStatementLines = 1`; anything longer opens a
block. CI runs the same command with `--verify-no-changes`. Lines stay under 120.

## XAML (`src/UI/`)

The same rule, measured across a whole `<!-- -->` span: one line, and two only for
a file header or a comment introducing an element or a section of a resource
dictionary. A comment restating a style's own `x:Key` earns nothing; delete it.
The user-facing text those files carry has its own rules in
[UI reference](./ui-reference.md#writing-ui-text).

## Formatting (automated)

The `Rules` section of `PSScriptAnalyzerSettings.psd1` is the repo's
".clang-format", mapped from Zephyr's:

| Zephyr `.clang-format`        | DONUT equivalent                                        |
| ----------------------------- | ------------------------------------------------------- |
| `ColumnLimit: 100`            | `PSAvoidLongLines` at 120 (PSScriptAnalyzer's default; a build gate) |
| `IndentWidth: 8` (tabs)       | 4-space indent, by review (the analyzer rule is off, see below) |
| `BreakBeforeBraces: Linux`    | Open brace same line; `} else {`, `} catch {` cuddled (1TBS) |
| `AlignConsecutiveMacros`      | Hashtable assignment alignment                           |
| proper capitalization         | `PSUseCorrectCasing`                                     |
| `InsertNewlineAtEndOfFile`    | Enforced by `Invoke-Format.ps1`                          |

```powershell
pwsh -File tools\Invoke-Format.ps1          # fix src\, tests\ and tools\ in place
pwsh -File tools\Invoke-Format.ps1 -Check   # CI / pre-commit gate
```

Beyond the analyzer's rules, `Invoke-Format.ps1` strips trailing whitespace from
every line outside a here-string (a fixture's trailing spaces may be the point) and
guarantees a final newline. The VS Code PowerShell extension picks up the same
settings file, so **Format Document** produces the same brace and whitespace shape.

## Linting

`tools/Invoke-Lint.ps1` runs PSScriptAnalyzer with the repo settings over `src/`,
`tests/` and `tools/`, then sweeps **every** PowerShell, C#, web, and XAML file in
the repo for the comment-length rule above. PSScriptAnalyzer has no such rule and
cannot parse the other languages at all, so nothing else would catch it. Run it (and
`Invoke-Format.ps1 -Check`) before committing; new findings are fixed, not
suppressed. Test files follow the same layout rules as source: a repeated setup
call becomes a `BeforeAll` helper rather than a wrapped one-liner in every `It`.

The comment sweep starts clean and gates unconditionally, so any hit is something
you just added. The `Invoke-StyleCheckForChange` hook applies the same rule per
edit, so it usually surfaces before the lint run does.

`PSAvoidLongLines` gates at 120 (PSScriptAnalyzer's default; the 100 in Zephyr's
table is a C column, and PowerShell's class nesting and cmdlet names spend it
fast). When a line is over, or a cmdlet call carries more than two named
parameters, go **one per line**, each continuation aligned under the first
parameter:

```powershell
$auth = Get-CimInstance -Namespace 'root\ccm' `
                        -ClassName 'SMS_Authority' `
                        -ErrorAction Stop
```

Constructor and method arguments split the same way inside the parentheses, and
array literals one element per line. A message string splits with `+` at a phrase
boundary; a one-line `try {} catch {}` opens up. Inside the here-string script
templates, break only where the shipped payload stays valid PowerShell (after a
comma, a pipe, or a doubled backtick). `PSUseConsistentIndentation` is off for
this reason: it has no alignment mode and would rewrite every such continuation
to one indent level, so 4-space block indentation is kept by review.

`TypeNotFound` also gates, but it is a parser diagnostic rather than a rule: the
lint session loads the WPF and WinForms assemblies first so every `[Brush]` and
`[DispatcherTimer]` resolves, and filters the runtime-compiled launcher types by
name. A hit therefore means a real typo in a type name, or a new runtime-compiled
type that needs adding to the filter in `Invoke-Lint.ps1`.

### The repo's own rules

`tools/Rules/DonutRules.psm1` holds the conventions no stock rule can express, and
`Invoke-Lint.ps1` loads it beside the stock set:

- **DonutParameterLayout** (Warning, gates): the one-per-line and alignment shape
  above, for calls with more than two named parameters, and alignment for any
  wrapped call. A call under 80 columns is left alone whatever it carries, and
  Pester's `Should` is exempt: its switches are assertion operators, not
  parameters, and `Should -Not -BeNullOrEmpty -Because '...'` reads as a sentence.
- **DonutFunctionSize** (Information, report only): a function or method past
  clang-tidy's `readability-function-size` limits (150 lines or 100 statements), or
  past 20 branches (every `if`/`elseif`/`else`, `switch` case, loop and `catch`) or
  five nested blocks. Reported, never gated: the handful of known hotspots
  (`Resolve-Lens`, `MainPresenter.Initialize`, `HomePresenter.OnJobCompleted`,
  `ResolutionCoordinator.CompleteResolveCore`, `WizTreeCsv.ParseTopFoldersFromFile`)
  print on every run so the list stays visible and cannot grow unnoticed. Split one
  when its file is next touched, and promote the rule to Warning once the list is
  empty. The thresholds are pylint's and clang-tidy's kind of limit, calibrated to
  this codebase: pylint's own 40-statement cap would flag a fifth of it.

Each rule is tested through the real analyzer on snippets in
`tests/Unit/DonutRules.Tests.ps1`.
