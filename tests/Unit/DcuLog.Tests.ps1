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

Describe "DcuLog return-code classification" {
    It "treats ONLY 0, 1, 5 as success (2/3/4 are real errors, not benign)" {
        foreach ($ok in 0, 1, 5) { [DcuLog]::IsSuccess($ok) | Should -BeTrue -Because "code $ok is success/reboot" }
        foreach ($bad in 2, 3, 4, 6, 7, 8, 105, 500, 1000) {
            [DcuLog]::IsSuccess($bad) | Should -BeFalse -Because "code $bad is a DCU error"
        }
    }

    It "flags 1 and 5 (only) as needing a reboot" {
        [DcuLog]::NeedsReboot(1) | Should -BeTrue
        [DcuLog]::NeedsReboot(5) | Should -BeTrue
        [DcuLog]::NeedsReboot(0) | Should -BeFalse
        [DcuLog]::NeedsReboot(2) | Should -BeFalse
    }

    It "describes the small codes by their real meaning" {
        [DcuLog]::DescribeReturnCode(2) | Should -Be 'unknown application error'
        [DcuLog]::DescribeReturnCode(3) | Should -Be 'the system manufacturer is not Dell'
        [DcuLog]::DescribeReturnCode(4) | Should -Be 'dcu-cli was not run with administrative privilege'
    }

    It "categorises the documented error ranges" {
        [DcuLog]::DescribeReturnCode(105)  | Should -Be 'input-validation error'
        [DcuLog]::DescribeReturnCode(500)  | Should -Be 'scan error'
        [DcuLog]::DescribeReturnCode(1000) | Should -Be 'apply-updates error'
        [DcuLog]::DescribeReturnCode(99999) | Should -Be 'error'
    }
}
