using module "..\..\src\Models\DcuLog.psm1"

Describe "DcuLog.ParseReturnCode" {
    It "pulls the return code from a real dcu-cli activity log tail" {
        $log = @"
[2026-07-02 15:15:43] : The scan result is VALID_RESULT
[2026-07-02 15:15:43] : Number of applicable updates for the current system configuration: 1
[2026-07-02 15:15:43] : Execution completed.
[2026-07-02 15:15:43] : The program exited with return code: 0
[2026-07-02 15:15:43] : State monitoring disposed for application domain dcu-cli.exe
"@
        $r = [DcuLog]::ParseReturnCode($log)
        $r.Found | Should -BeTrue
        $r.Code  | Should -Be 0
    }

    It "takes the LAST return code when several runs are present (append-safe)" {
        $log = "The program exited with return code: 0`nThe program exited with return code: 1"
        $r = [DcuLog]::ParseReturnCode($log)
        $r.Found | Should -BeTrue
        $r.Code  | Should -Be 1
    }

    It "reports Found=false when no return-code line is present (dcu-cli didn't finish)" {
        $log = "[2026-07-02 15:15:01] : Determining available updates..."
        $r = [DcuLog]::ParseReturnCode($log)
        $r.Found | Should -BeFalse
        $r.Code  | Should -Be 0
    }

    It "reports Found=false for blank/null input" {
        ([DcuLog]::ParseReturnCode('')).Found   | Should -BeFalse
        ([DcuLog]::ParseReturnCode($null)).Found | Should -BeFalse
    }

    It "parses a non-zero DCU error code" {
        $r = [DcuLog]::ParseReturnCode("The program exited with return code: 500")
        $r.Found | Should -BeTrue
        $r.Code  | Should -Be 500
    }

    It "is case/spacing tolerant" {
        $r = [DcuLog]::ParseReturnCode("...Return Code:   2")
        $r.Found | Should -BeTrue
        $r.Code  | Should -Be 2
    }
}
