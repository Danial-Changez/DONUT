class RunspaceManager {
    static [System.Management.Automation.Runspaces.RunspacePool] $RunspacePool

    static [void] Initialize() {
        [RunspaceManager]::Initialize(1, 5)
    }

    static [void] Initialize([int]$MinRunspaces, [int]$MaxRunspaces) {
        if (-not [RunspaceManager]::RunspacePool) {
            [RunspaceManager]::RunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool($MinRunspaces, $MaxRunspaces)
            [RunspaceManager]::RunspacePool.Open()
        }
    }

    static [System.Management.Automation.Runspaces.RunspacePool] GetPool() {
        if (-not [RunspaceManager]::RunspacePool) { 
            [RunspaceManager]::Initialize() 
        }
        return [RunspaceManager]::RunspacePool
    }

    static [void] Close() {
        if ([RunspaceManager]::RunspacePool) {
            [RunspaceManager]::RunspacePool.Close()
            [RunspaceManager]::RunspacePool.Dispose()
            [RunspaceManager]::RunspacePool = $null
        }
    }
}
