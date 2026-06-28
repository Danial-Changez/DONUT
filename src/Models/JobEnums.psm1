# JobEnums
#
# Execution-state vocabulary for background AsyncJobs, promoted from loose
# strings to enums so the job state machine is typo-proof. Kept in Models
# (dependency-free) so Core (AsyncJob) can reference them without a layering
# cycle. PowerShell coerces between an enum and its member name, so the pure
# string-based presentation mapper (FleetStatus) and the existing tests keep
# working unchanged.

# Lifecycle state of an AsyncJob.
enum JobStatus {
    Created
    Running
    Completed
    Failed
}

# The kind of remote operation a job performs.
enum JobKind {
    Scan
    UpdateScan
    UpdateApply
    Inventory
}
