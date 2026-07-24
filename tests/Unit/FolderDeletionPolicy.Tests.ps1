using module "..\..\src\Models\FolderDeletionPolicy.psm1"

Describe "FolderDeletionPolicy" {
    Context "IsDeletable" {
        It "allows ordinary folders and user subfolders" {
            [FolderDeletionPolicy]::IsDeletable('C:\temp') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Users\john\Downloads') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Users\john') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Intel\Logs') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\temp\') | Should -BeTrue   # trailing slash
        }

        It "blocks the volume root and blank/null paths" {
            [FolderDeletionPolicy]::IsDeletable('C:\') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable($null) | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('   ') | Should -BeFalse
        }

        It "blocks the Users container itself but not its children" {
            [FolderDeletionPolicy]::IsDeletable('C:\Users') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\users\') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Users\Public\Downloads') | Should -BeTrue
        }

        It "blocks protected system directories and everything under them (case-insensitive)" {
            [FolderDeletionPolicy]::IsDeletable('C:\Windows') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\windows\Installer') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Program Files\Dell') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Program Files (x86)\App') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\ProgramData\Foo') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\System Volume Information') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\$Recycle.Bin\S-1-5') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Recovery') | Should -BeFalse
        }
    }
}
