Describe "Lens device detail query" {

    BeforeAll {
        # Dot-sourcing is safe off Windows because the [ADSI] binds live inside script blocks.
        . (Join-Path $PSScriptRoot '..\..\src\Scripts\LensAgent.Common.ps1')
        $script:Device = $script:DeviceScript
    }

    It "degrades to a noted row when the directory is unreachable" {
        $dev = & $script:Device 'DC=invalid,DC=example' 'WS-X'

        $dev.name | Should-Be 'WS-X'
        # The failure lands in the note, and the row still carries its full shape.
        ($dev.note.Length -gt 0) | Should-BeTrue
        @($dev.bitLockerKeys).Count | Should-Be 0
        $dev.os | Should-Be ''
        # The wall time feeds the stage marks debug logging prints.
        ($dev.ms -ge 0) | Should-BeTrue
    }

    It "unreachable fallback domains still end in a noted row, not a throw" {
        $dev = & $script:Device 'DC=invalid,DC=example' 'WS-X' @('invalid.example', '')

        $dev.name | Should-Be 'WS-X'
        $dev.note | Should-Be 'computer object not found in AD'
    }
}
