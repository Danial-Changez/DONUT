using module "..\..\src\Core\LogService.psm1"

# Shared test double: an in-memory LogService that captures entries instead of
# writing to disk, so tests can assert on the levels/messages a unit emits.
# Inject it wherever a [LogService] dependency is accepted.
class CapturingLogService : LogService {
    [System.Collections.Generic.List[string]] $Entries

    CapturingLogService() : base() {
        $this.Entries = [System.Collections.Generic.List[string]]::new()
    }

    [void] WriteLog([string]$level, [string]$message) {
        $this.Entries.Add("[$level] $message")
    }

    # True if any captured entry was written at the given level.
    [bool] HasLevel([string]$level) {
        foreach ($entry in $this.Entries) {
            if ($entry.StartsWith("[$level]")) { return $true }
        }
        return $false
    }

    # True if any captured entry contains the given substring.
    [bool] Contains([string]$text) {
        foreach ($entry in $this.Entries) {
            if ($entry -like "*$text*") { return $true }
        }
        return $false
    }
}
