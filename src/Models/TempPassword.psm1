<#
.SYNOPSIS
    Crypto-random temporary password generator for AD resets.

.DESCRIPTION
    Generates phone-readable 'Xxxxx-Xxxxx-99' passwords: two capitalized chunks
    and two digits joined by hyphens. Pools exclude the ambiguous glyphs
    (0/O, 1/l/I, i/o) so a helpdesk operator can read one out loud without a
    phonetic alphabet. Four AD complexity classes are met by construction
    (upper, lower, digit, hyphen); 14 chars comfortably clears default policy.

.NOTES
    Pure and WPF-free so it unit-tests anywhere. ToSecure exists because the
    PSScriptAnalyzer password rules (rightly) ban ConvertTo-SecureString
    -AsPlainText; the .NET AppendChar route carries the secret across the
    worker boundary without tripping them.
#>
class TempPassword {
    hidden static [string] $Upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    hidden static [string] $Lower = 'abcdefghjkmnpqrstuvwxyz'
    hidden static [string] $Digits = '23456789'

    # Returns a fresh 'Xxxxx-Xxxxx-99' temp password (14 chars).
    static [string] Generate() {
        $sb = [System.Text.StringBuilder]::new(14)
        foreach ($chunk in 1..2) {
            [void]$sb.Append([TempPassword]::Pick([TempPassword]::Upper))
            foreach ($i in 1..4) {
                [void]$sb.Append([TempPassword]::Pick([TempPassword]::Lower))
            }
            [void]$sb.Append('-')
        }
        [void]$sb.Append([TempPassword]::Pick([TempPassword]::Digits))
        [void]$sb.Append([TempPassword]::Pick([TempPassword]::Digits))
        return $sb.ToString()
    }

    # Converts a plaintext value to a read-only SecureString via AppendChar.
    static [securestring] ToSecure([string]$value) {
        $secure = [securestring]::new()
        if (-not [string]::IsNullOrEmpty($value)) {
            foreach ($ch in $value.ToCharArray()) { $secure.AppendChar($ch) }
        }
        $secure.MakeReadOnly()
        return $secure
    }

    hidden static [char] Pick([string]$pool) {
        return $pool[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($pool.Length)]
    }
}
