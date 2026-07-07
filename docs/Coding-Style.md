# DONUT Coding Style

Comment and layout conventions for the PowerShell sources under `src/`. The rules
are adapted from the [Zephyr RTOS coding style](https://docs.zephyrproject.org/latest/contribute/style/code.html)
and [documentation guidelines](https://docs.zephyrproject.org/latest/contribute/documentation/guidelines.html),
translated to PowerShell.

## Comments

**Comments explain *why*, never *what*.** The code already says what it does; a
comment earns its place only by stating something the code cannot show — a
constraint, a hazard, a protocol quirk, or a decision that would otherwise be
re-litigated:

```powershell
# WaitHandle.WaitAll throws on an STA thread, so wait per-handle with WaitOne.
```

Never narrate the next line:

```powershell
# Populate fields          <- delete: the call below says exactly this
$this.PopulateFields()
```

**Keep them short.** One line preferred, two lines maximum. If a rationale
genuinely needs more, it belongs in the file's `.NOTES` block, with inline
comments pointing at it (`see .NOTES`).

**Doc comments on the API.** The PowerShell equivalents of Zephyr's Doxygen
comments:

- Every module (`.psm1`) and entry script (`.ps1`) opens with comment-based help:
  `.SYNOPSIS` (one line), `.DESCRIPTION` (what it owns and how it fits), and
  `.NOTES` for cross-cutting constraints (threading rules, transport gates,
  security invariants) that inline comments can reference.
- Every class and non-trivial public method gets a brief `#` doc comment directly
  above it stating its contract — purpose, return semantics, and any caller-facing
  constraint. State what the signature can't show; don't restate the name or type
  (Zephyr's Doxygen rule). Trivial getters/setters need none.
- Fields get a short trailing `# comment` only when the type/name doesn't already
  say it (units, ownership, lifetime).

**Layout.**

- Comments wrap at ~90 columns (hard cap 100, matching Zephyr).
- Sentence case; capitalize acronyms properly (`DCU`, `SMB`, `UNC`). No
  all-caps emphasis (`NEVER`, `WITHOUT`) — if a point needs stress, say why
  instead.
- Prefer ASCII; **never emojis** (Zephyr: "avoid using non-ASCII symbols in code,
  unless it significantly improves clarity, avoid emojis in any case"). Non-ASCII
  punctuation is acceptable only where it genuinely reads better.
- Section separators, used sparingly in files large enough to need navigation,
  are exactly `# --- Section name ---` (no long dash padding, no `====`).

## Code

- No trailing whitespace; spaces around operators (`$x = if (...)`, never
  `$x =if (...)`).
- Follow the style of the surrounding code when these rules are silent
  (Zephyr's own fallback rule).
- Comments inside remote-script here-string templates (e.g.
  `InventoryService::BuildProbeScript`) are part of the shipped payload string —
  edit them only deliberately, never as part of a style sweep.

## C# (`src/Launcher/`)

The launcher and the `Donut.Mvvm` base types are C#. The same "why, not what"
rule applies, expressed in C#'s native Doxygen equivalent — **XML documentation
comments** (`///`). Zephyr's [Doxygen style](https://docs.zephyrproject.org/latest/contribute/style/doxygen.html)
scopes this to the **public API**, and warns *"don't restate the identifier or
the type"* — so document what the signature can't show, and nothing that just
echoes it:

- **Public types and non-trivial public members** get a `///` `<summary>` stating
  the contract. Add `<param>` / `<returns>` / `<exception>` only where they carry
  something the signature doesn't — valid values/ranges, units, nullability,
  ownership/lifetime, or the *why*; `<remarks>` for cross-cutting notes (threading,
  idempotency). Reference other types with `<see cref="..."/>`.
- **Trivial members need none.** An obvious auto-property (`FillColor`), a
  setup-only constructor, a self-describing one-liner — leave undocumented rather
  than add a `<summary>` that restates the name. (Same as the PowerShell rule:
  "trivial getters/setters need none.")
- **Internal/private members are not API.** A plain `//` comment for the *why* is
  enough — no `///` (Zephyr excludes internals from Doxygen entirely). Inline `//`
  notes sit below any `///` doc, never replace it.
- **Interface implementations** use `/// <inheritdoc/>` instead of restating the
  interface's contract.
- Nullable reference types are on (`<Nullable>enable</Nullable>` /
  `#nullable enable`); annotate nullability honestly (`object?`, `Foo?`) so the
  compiler stays quiet — see the `RelayCommand` / `ObservableObject` signatures.
- WinForms custom controls mark code-only public properties
  `[DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]`
  (analyzer **WFO1000**); they are never placed on a designer surface.
- Section separators match the PowerShell rule: `// --- Section name ---`.

Doc-file generation (`GenerateDocumentationFile`) is intentionally **off**: the
docs are for readers, not a published API surface, so missing-doc warnings
(CS1591) are not a build gate.

## Formatting (automated)

The `Rules` section of `PSScriptAnalyzerSettings.psd1` is the repo's
".clang-format", mapped from [Zephyr's](https://github.com/zephyrproject-rtos/zephyr/blob/main/.clang-format)
with PowerShell idiom where C conventions don't translate:

| Zephyr `.clang-format`        | DONUT equivalent                                        |
| ----------------------------- | ------------------------------------------------------- |
| `ColumnLimit: 100`            | `PSAvoidLongLines` at 100 (reported, not build-breaking) |
| `IndentWidth: 8` (tabs)       | 4-space indent (`PSUseConsistentIndentation`)            |
| `BreakBeforeBraces: Linux`    | Open brace on the same line; `else`/`catch` on their own line (the repo's dominant style, per Zephyr's "follow existing code" fallback) |
| `AlignConsecutiveMacros`      | Hashtable assignment alignment                           |
| proper capitalization         | `PSUseCorrectCasing` (cmdlet/keyword casing)             |
| `InsertNewlineAtEndOfFile`    | Enforced by `Invoke-Format.ps1`                          |

`tools/Invoke-Format.ps1` applies these rules with `Invoke-Formatter`:

```powershell
pwsh -File tools\Invoke-Format.ps1          # fix src\ in place
pwsh -File tools\Invoke-Format.ps1 -Check   # CI / pre-commit gate: exit 1 if unformatted
```

The VS Code PowerShell extension picks up the same settings file, so
**Format Document** produces identical output.

## Linting

`tools/Invoke-Lint.ps1` runs PSScriptAnalyzer with the repo settings
(`PSScriptAnalyzerSettings.psd1`) over `src/`. Run it (and
`Invoke-Format.ps1 -Check`) before committing; new findings should be fixed,
not suppressed.

`PSAvoidLongLines` (the 100-column rule) is report-only, not a lint gate: a
first pass rewrapped ~340 pre-existing violations down to ~160, but a line is
left long when wrapping would hurt more than help — long URLs/reference
links, the `InventoryService`/`WorkerServices` here-string script templates
(edited only deliberately, never for style), and a handful of long operator
chains, CIM `-Filter` strings, and error-message literals where a mid-string
break reads worse than the overrun. Use judgment the same way when adding new
code: wrap when it's free, don't mangle a string literal to hit the count.
