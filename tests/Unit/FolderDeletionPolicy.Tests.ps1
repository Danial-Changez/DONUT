using module "..\..\src\Models\FolderDeletionPolicy.psm1"

Describe "FolderDeletionPolicy" {
    Context "IsDeletable" {
        It "allows ordinary folders and user subfolders" {
            [FolderDeletionPolicy]::IsDeletable('C:\temp') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Users\john\Downloads') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Users\john') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Intel\Logs') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\temp\') | Should -BeTrue   # Trailing slash.
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
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\System32') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Program Files\Dell') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Program Files (x86)\App') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\ProgramData\Foo') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\System Volume Information') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\$Recycle.Bin\S-1-5') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Recovery') | Should -BeFalse
        }

        It "allows known safe caches under Windows (and their contents), not siblings" {
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\ccmcache') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\windows\CCMCache\a1b2') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\Temp') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\SoftwareDistribution\Download') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\Prefetch') | Should -BeTrue
            # A prefix collision must not slip through, ccmcache2 is not ccmcache.
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\ccmcache2') | Should -BeFalse
            # The whole SoftwareDistribution is Windows Update state, so only Download is safe.
            [FolderDeletionPolicy]::IsDeletable('C:\Windows\SoftwareDistribution') | Should -BeFalse
        }

        It "blocks protected dirs reached through '..' traversal" {
            [FolderDeletionPolicy]::IsDeletable('C:\temp\..\Windows\System32') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Users\john\..\..\Program Files') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:/temp/../Windows') | Should -BeFalse
            # Walking above the volume root is refused outright rather than clamped to "C:\".
            [FolderDeletionPolicy]::IsDeletable('C:\temp\..\..\Windows') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\..\Windows') | Should -BeFalse
        }

        It "blocks protected dirs disguised by trailing dots, spaces, or 8.3 aliases" {
            [FolderDeletionPolicy]::IsDeletable('C:\Windows.\System32') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Windows \System32') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\PROGRA~1\App') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('C:\Users.') | Should -BeFalse
        }

        It "rejects paths that are not plain local drive paths" {
            [FolderDeletionPolicy]::IsDeletable('\\?\C:\Windows') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('\\server\share\folder') | Should -BeFalse
            [FolderDeletionPolicy]::IsDeletable('temp\sub') | Should -BeFalse
        }

        It "still resolves harmless traversal to the folder it actually names" {
            [FolderDeletionPolicy]::IsDeletable('C:\temp\.\sub') | Should -BeTrue
            [FolderDeletionPolicy]::IsDeletable('C:\foo\..\temp') | Should -BeTrue
            # Canonicalizing into an allowed cache is a real allow, not a bypass.
            [FolderDeletionPolicy]::IsDeletable('C:\temp\..\Windows\ccmcache') | Should -BeTrue
        }
    }

    Context "Canonicalize" {
        It "returns the resolved path for usable inputs" {
            [FolderDeletionPolicy]::Canonicalize('C:\temp\..\Windows\System32') | Should -BeExactly 'C:\Windows\System32'
            [FolderDeletionPolicy]::Canonicalize('C:/temp/sub/') | Should -BeExactly 'C:\temp\sub'
            [FolderDeletionPolicy]::Canonicalize('C:\temp\.\sub') | Should -BeExactly 'C:\temp\sub'
            [FolderDeletionPolicy]::Canonicalize('C:\Windows.\System32') | Should -BeExactly 'C:\Windows\System32'
        }

        It "returns null for the volume root, escapes, and unusable inputs" {
            [FolderDeletionPolicy]::Canonicalize('C:\') | Should -BeNullOrEmpty
            [FolderDeletionPolicy]::Canonicalize('C:\temp\..') | Should -BeNullOrEmpty
            [FolderDeletionPolicy]::Canonicalize('C:\..\Windows') | Should -BeNullOrEmpty
            [FolderDeletionPolicy]::Canonicalize('C:\PROGRA~1') | Should -BeNullOrEmpty
            [FolderDeletionPolicy]::Canonicalize('') | Should -BeNullOrEmpty
            [FolderDeletionPolicy]::Canonicalize($null) | Should -BeNullOrEmpty
        }
    }
}
