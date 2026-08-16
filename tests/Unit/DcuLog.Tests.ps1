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

    It "names the documented scan, apply, and catalog codes individually" {
        [DcuLog]::DescribeReturnCode(112) | Should -Be 'an invalid catalog was provided'
        [DcuLog]::DescribeReturnCode(500) | Should -Be 'no updates were found for the system'
        [DcuLog]::DescribeReturnCode(501) | Should -Be 'an error occurred while determining the available updates'
        [DcuLog]::DescribeReturnCode(502) | Should -Be 'the scan was canceled'
        [DcuLog]::DescribeReturnCode(503) | Should -Be 'a download error occurred during the scan'
        [DcuLog]::DescribeReturnCode(1001) | Should -Be 'the apply-updates operation was canceled'
    }

    It "names the Dell Client Management Service states with a next step" {
        [DcuLog]::DescribeReturnCode(3000) | Should -BeLike 'the Dell Client Management Service is not running*retry*'
        [DcuLog]::DescribeReturnCode(3002) | Should -BeLike 'the Dell Client Management Service is disabled*enable*'
    }

    It "categorises the documented error ranges" {
        [DcuLog]::DescribeReturnCode(105)  | Should -Be 'input-validation error'
        [DcuLog]::DescribeReturnCode(1505) | Should -Be 'configure error'
        [DcuLog]::DescribeReturnCode(2500) | Should -Be 'password-encryption error'
        [DcuLog]::DescribeReturnCode(99999) | Should -Be 'error'
    }
}

Describe "DcuLog.Classify (per-command)" {
    It "treats a scan 500 as a clean no-updates result, not a failure" {
        [DcuLog]::Classify('scan', 500) | Should -Be ([DcuCommandOutcome]::NoUpdates)
    }

    It "keeps 500 a failure for every other command" {
        [DcuLog]::Classify('applyUpdates', 500) | Should -Be ([DcuCommandOutcome]::Failed)
    }

    It "classifies 0 as success and 1/5 as reboot-required for any command" {
        [DcuLog]::Classify('scan', 0) | Should -Be ([DcuCommandOutcome]::Success)
        [DcuLog]::Classify('scan', 1) | Should -Be ([DcuCommandOutcome]::RebootRequired)
        [DcuLog]::Classify('applyUpdates', 1) | Should -Be ([DcuCommandOutcome]::RebootRequired)
        [DcuLog]::Classify('scan', 5) | Should -Be ([DcuCommandOutcome]::RebootRequired)
    }

    It "keeps real errors failures on both commands" {
        [DcuLog]::Classify('scan', 501) | Should -Be ([DcuCommandOutcome]::Failed)
        [DcuLog]::Classify('applyUpdates', 3000) | Should -Be ([DcuCommandOutcome]::Failed)
    }
}
