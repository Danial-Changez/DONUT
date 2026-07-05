# DONUT Coding Style

Comment and layout conventions for the PowerShell sources under `src/`. The rules
are adapted from the [Zephyr RTOS coding style](https://docs.zephyrproject.org/latest/contribute/style/code.html)
and its inline-documentation guidelines, translated to PowerShell.

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
  constraint. Trivial getters/setters need none.
- Fields get a short trailing `# comment` only when the type/name doesn't already
  say it (units, ownership, lifetime).

**Layout.**

- Comments wrap at ~90 columns (hard cap 100, matching Zephyr).
- Sentence case; capitalize acronyms properly (`DCU`, `SMB`, `UNC`). No
  all-caps emphasis (`NEVER`, `WITHOUT`) — if a point needs stress, say why
  instead.
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
