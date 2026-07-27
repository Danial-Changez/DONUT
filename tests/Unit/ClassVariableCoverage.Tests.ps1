<#
    Regression guard for the "the class loads fine, then explodes the moment you use
    it" bug: a class method that READS a variable it never assigns is NOT a parse
    error. PowerShell throws "Variable is not assigned in the method." at invocation
    time, so it slips past import, `using module`, and every load-level check here.

    It cost a full field round. StartupTaskService.RegisterTask still interpolated
    "$user" after that parameter was renamed $triggerUser, so the startup toggle came
    back as a MethodInvocationException on a real machine instead of a task - and the
    fakes the unit tests use override RegisterTask, so nothing local ever ran it.
#>

Describe "Class method variable coverage" {

    BeforeAll {
        $script:SrcRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../src'))

        # Readable without assignment: automatic variables + $this.
        $script:Automatic = @(
            'this', 'true', 'false', 'null', '_', 'PSItem', 'args', 'input', 'error',
            'PSScriptRoot', 'PSCommandPath', 'MyInvocation', 'PSVersionTable', 'PSCmdlet',
            'PSBoundParameters', 'PID', 'Host', 'ExecutionContext', 'PWD', 'HOME', 'PSHOME',
            'LASTEXITCODE', 'StackTrace', 'switch', 'foreach', 'matches', 'IsWindows',
            'IsLinux', 'IsMacOS', 'ErrorActionPreference', 'ProgressPreference', 'PSStyle',
            'VerbosePreference', 'WarningPreference', 'InformationPreference', 'PSEdition',
            'DebugPreference', 'ConfirmPreference', 'OutputEncoding', 'PSDefaultParameterValues'
        )

        # Built with the type name inlined: FindAll runs its predicate through a
        # delegate, where a closed-over $kind variable would not resolve.
        $script:Predicate = @{}
        foreach ($kind in @('TypeDefinitionAst', 'FunctionMemberAst', 'VariableExpressionAst',
                'AssignmentStatementAst', 'ForEachStatementAst', 'ParamBlockAst',
                'FunctionDefinitionAst', 'CommandParameterAst')) {
            $script:Predicate[$kind] = [scriptblock]::Create(
                "param(`$n) `$n -is [System.Management.Automation.Language.$kind]")
        }

        function Find-Ast([object]$ast, [string]$kind) {
            return $ast.FindAll($script:Predicate[$kind], $true)
        }

        # Every name the method binds: its own parameters, anything it assigns, the
        # foreach/param variables of nested scriptblocks, and -*Variable capture targets.
        function Get-BoundNames([object]$method) {
            $names = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
            foreach ($p in $method.Parameters) { [void]$names.Add($p.Name.VariablePath.UserPath) }
            foreach ($a in (Find-Ast $method 'AssignmentStatementAst')) {
                foreach ($v in (Find-Ast $a.Left 'VariableExpressionAst')) {
                    [void]$names.Add($v.VariablePath.UserPath)
                }
            }
            foreach ($f in (Find-Ast $method 'ForEachStatementAst')) {
                [void]$names.Add($f.Variable.VariablePath.UserPath)
            }
            foreach ($pb in (Find-Ast $method 'ParamBlockAst')) {
                foreach ($p in $pb.Parameters) { [void]$names.Add($p.Name.VariablePath.UserPath) }
            }
            foreach ($fn in (Find-Ast $method 'FunctionDefinitionAst')) {
                foreach ($p in @($fn.Parameters)) { [void]$names.Add($p.Name.VariablePath.UserPath) }
            }
            foreach ($cp in (Find-Ast $method 'CommandParameterAst')) {
                if ($cp.ParameterName -match '^(Error|Out|Warning|Information|Pipeline)Variable$' -and
                    $cp.Argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    [void]$names.Add($cp.Argument.Value)
                }
            }
            return $names
        }
    }

    It "no class method reads a variable it never assigns" {
        $violations = @()
        $checked = 0
        foreach ($file in (Get-ChildItem -Path $SrcRoot -Recurse -Include '*.psm1', '*.ps1' -File)) {
            $ast = [System.Management.Automation.Language.Parser]::ParseFile(
                $file.FullName, [ref]$null, [ref]$null)
            foreach ($type in (Find-Ast $ast 'TypeDefinitionAst')) {
                if (-not $type.IsClass) { continue }
                foreach ($method in (Find-Ast $type 'FunctionMemberAst')) {
                    $checked++
                    $bound = Get-BoundNames $method
                    foreach ($v in (Find-Ast $method 'VariableExpressionAst')) {
                        # Scope/drive-qualified ($env:, $script:, $using:) resolve outside the method.
                        if (-not $v.VariablePath.IsUnqualified) { continue }
                        $name = $v.VariablePath.UserPath
                        if ($bound.Contains($name) -or $name -in $script:Automatic) { continue }
                        $violations += "$($file.Name):$($v.Extent.StartLineNumber) $($type.Name).$($method.Name) reads `$$name, which it never assigns"
                    }
                }
            }
        }
        $violations | Should -BeNullOrEmpty -Because (
            'PowerShell only raises "Variable is not assigned in the method." when the ' +
            'method runs, so a missed rename ships as a field crash (the startup-task regression)')
        # If this drops to zero the walk went blind (moved classes, renamed AST types), not clean.
        $checked | Should -BeGreaterThan 0
    }
}
