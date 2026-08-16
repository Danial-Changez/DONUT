@{
    # PSScriptAnalyzer configuration for DONUT.
    #
    # The VS Code PowerShell extension auto-detects this file at the workspace root
    # (live squiggles + Format Document). For a repo-wide run, target source only and
    # skip build output:
    #
    #   $files = Get-ChildItem .\src -Recurse -Include *.ps1,*.psm1 -File |
    #               Where-Object { $_.FullName -notmatch '\\(bin|obj)\\' }
    #   $files | ForEach-Object { Invoke-ScriptAnalyzer -Path $_.FullName -Settings .\PSScriptAnalyzerSettings.psd1 }
    #
    # Rules are excluded below ONLY where they are either false positives against
    # DONUT's class-based / runspace design or flag a documented, deliberate choice.
    # Everything else stays on so real sloppiness (aliases, positional params, stray
    # whitespace, $null-comparison order, automatic-variable shadowing) still surfaces.

    # NOTE on TypeNotFound: PSSA emits it from the PARSER, not the rule engine, so it
    # canNOT be suppressed here (listing it in ExcludeRules has no effect). The parser
    # resolves type literals against the session's loaded assemblies, so
    # tools\Invoke-Lint.ps1 loads the WPF/WinForms assemblies first and filters the
    # runtime-compiled launcher types (ObservableObject / RelayCommand / Donut.Interop.*)
    # by name. The VS Code extension's own session loads neither, so it still squiggles
    # them harmlessly.

    ExcludeRules = @(
        # --- False positives from the class-based / runspace design ---------------
        # Class method / WPF event-handler / interface-conformant signatures keep
        # parameters they don't all read (e.g. OnTimerTick($sender, $e)); the rule
        # can't see that the signature is fixed by its caller.
        'PSReviewUnusedParameter'

        # DONUT threads state into runspaces/ThreadJobs via param() + -ArgumentList
        # (the correct alternative to $using:), which this rule doesn't recognize.
        'PSUseUsingScopeModifierInNewRunspaces'

        # --- Deliberate, documented design choices --------------------------------
        # Composition-root startup progress goes to the console before the UI exists.
        'PSAvoidUsingWriteHost'

        # $global:AppConfig is the single composition-root config handle by design.
        'PSAvoidGlobalVars'

        # State-changing verbs here are internal class methods, not public cmdlets,
        # so -WhatIf/-Confirm plumbing does not apply.
        'PSUseShouldProcessForStateChangingFunctions'

        # DONUT requires pwsh 7 (UTF-8 default); a BOM is unnecessary and churns diffs.
        # NOTE: the Lens agent path (#Requires -Version 5.1) can run under Windows
        # PowerShell 5.1 - if any of those files carry non-ASCII text, add a BOM to
        # THOSE files specifically rather than re-enabling this rule globally.
        'PSUseBOMForUnicodeEncodedFile'

        # Best-effort catches are a deliberate, pervasive pattern (crypto disposal,
        # heartbeat writes, warm jobs). Suppressed so the recurring signal stays
        # actionable - audit these by hand once instead (a comment does NOT satisfy
        # this rule; only a real statement or suppression does).
        'PSAvoidUsingEmptyCatchBlock'
    )

    # Formatting rules - DONUT's ".clang-format". Mapped from Zephyr's
    # (https://github.com/zephyrproject-rtos/zephyr/blob/main/.clang-format) with
    # PowerShell idiom where C conventions don't translate:
    #   ColumnLimit 100            -> PSAvoidLongLines at 120 (PSSA's default; PowerShell's
    #                                 class nesting and cmdlet names eat 100 fast), gating
    #   IndentWidth 8 / tabs       -> 4-space indent (the PowerShell convention; by review,
    #                                 since the analyzer's rule is off, see below)
    #   BreakBeforeBraces: Linux   -> open brace on the same line, and else/catch/finally
    #                                 cuddled after the closing brace (1TBS, "} else {")
    #   AlignConsecutiveMacros     -> align hashtable assignments
    #   InsertNewlineAtEndOfFile   -> enforced by tools\Invoke-Format.ps1
    # These rules are used by tools\Invoke-Format.ps1 (Invoke-Formatter), the VS Code
    # Format Document command, and surface as lint findings in tools\Invoke-Lint.ps1.
    Rules = @{
        PSPlaceOpenBrace = @{
            Enable             = $true
            OnSameLine         = $true
            NewLineAfter       = $true
            IgnoreOneLineBlock = $true
        }
        PSPlaceCloseBrace = @{
            Enable             = $true
            NewLineAfter       = $false   # "} else {", "} catch {": 1TBS
            IgnoreOneLineBlock = $true
            NoEmptyLineBefore  = $false
        }
        # Off, deliberately: multi-parameter calls continue with each parameter aligned
        # under the first (see coding-style.md), and this rule has no alignment mode, it
        # rewrites every such continuation to one indent level. Indentation stays 4-space
        # by convention, kept by review rather than by the formatter.
        PSUseConsistentIndentation = @{
            Enable = $false
        }
        PSUseConsistentWhitespace = @{
            Enable          = $true
            CheckInnerBrace = $true
            CheckOpenBrace  = $true
            CheckOpenParen  = $true
            CheckPipe       = $true
            CheckSeparator  = $true
            # Incompatible with PSAlignAssignmentStatement (it flags the alignment
            # padding), so alignment wins and operator spacing stays off.
            CheckOperator   = $false
        }
        PSUseCorrectCasing = @{
            Enable = $true
        }
        PSAlignAssignmentStatement = @{
            Enable         = $true
            CheckHashtable = $true
        }
        PSAvoidLongLines = @{
            Enable            = $true
            MaximumLineLength = 120
        }
    }
}
