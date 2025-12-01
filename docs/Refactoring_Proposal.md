# DONUT Refactoring Proposal

This document serves as the proposal/guide for refactoring the DONUT project from a script-based architecture to an OOP structure. There is no support for this implementation, and is being refactored to test what I have learnt.

## 1. Directory Structure

The new structure is to emphasize testability.

```text
root/
├── assets/                 <-- Assets (images)
│   └── Images/
├── bin/                    <-- Binaries/Dependencies
├── config/                 <-- Configuration files (config.json)
├── docs/                   <-- Documentation
├── src/                    <-- Source Code
│   ├── Core/               <-- Base classes, Interfaces, Enums
│   ├── Models/             <-- Data classes (DeviceContext, AppConfig)
│   ├── Services/           <-- Logic (RemoteService, UpdateService, DriverMatchingService)
│   ├── Scripts/            <-- Standalone scripts (e.g., InstallWorker)
│   ├── UI/                 <-- UI Layer
│   │   ├── Views/          <-- XAML files
│   │   ├── Styles/         <-- XAML styles
│   │   ├── Controllers/    <-- UI Logic/Controllers
│   └── Start-Donut.ps1     <-- Entry point for Startup.pss
├── tests/                  <-- Pester Tests
│   ├── Unit/
│   └── Integration/
├── logs/                   <-- Runtime generated logs
├── reports/                <-- Runtime generated reports
├── README.md
└── LICENSE
```

### Key Changes
1.  **`src/UI`**: Moves `Views` and `Styles` from the root into `src`. This groups all application code together.
2.  **`src/Models` & `src/Services`**: Separates data structures from logic.
3.  **`assets`**: Cleans up the root by grouping `Images` and `res`.
4.  **`tests`**: Adds a dedicated location for Pester tests.
5.  **No Battery feature (yet):** Battery reporting is a future-scope item and is removed from the current diagrams/structure.

---

## 2. Implementation Considerations

This section addresses how the refactor handles design choices and limitations identified in the original project.

### Parallel Execution (Runspaces)
**Challenge:** The original project uses PowerShell Runspaces for parallel execution.

**Refactor Strategy:**
- **Classes in Runspaces:** PowerShell classes are not automatically available in new runspaces. The `MainController` must explicitly load the required class modules (`Models`, `Services`) into each runspace before execution.
- **Thread Safety:** The `LogService` must be thread-safe. We will use a **Synchronized Wrapper** pattern (similar to the existing `$script:SyncUI` implementation).
    - The `MainController` creates a thread-safe collection (i.e. `[System.Collections.Concurrent.ConcurrentQueue[string]]`).
    - This collection is passed into the Runspace and injected into `RemoteExecutionService`.
    - The Service writes logs to this queue.
    - The `MainController` polls this queue on the UI thread (via a DispatcherTimer) to update the View.
    - *Why not return results?* Returning results only happens when the runspace completes. We need real-time feedback for the "Live Feed" feature.

### Remote Execution (PsExec)
**Challenge:** Reliance on `PsExec` and handling specific error codes (RPC, DNS).

*Rationale:* `PsExec` is retained as the primary execution engine because it offers superior reliability compared to native PowerShell Remoting (`Invoke-Command`). It operates over SMB (port 445), avoiding WinRM configuration issues (e.g., managing TrustedHosts lists), and natively supports execution as the `SYSTEM` account.

**Refactor Strategy:**
- **Encapsulation:** The `RemoteExecutionService` will wrap the `PsExec` calls.
- **Validation:** The `NetworkProbe` class will handle the pre-run checks (DNS, Reverse-DNS, RPC) currently in `remoteDCU.ps1`. This isolates the network logic from the execution logic.
- **Maintain remote file handling:** Preserve UNC copy of remote `outputLog` and `report` files, including per-host temporary logs and report XML consolidation before writing to local logs. Keep the pre-stop of `DellCommandUpdate` before running DCU.

### The `InstallWorker.ps1` Script
**Challenge:** This script is copied to `%LOCALAPPDATA%` and runs independently to handle updates/rollbacks.

**Refactor Strategy:**
- **Standalone Script:** `InstallWorker.ps1` should **not** be converted into a class. It must remain a standalone script file in `src/Scripts/` so it can be easily copied and executed by the `UpdateService`.
- **Resource Loading:** The `UpdateService` will need to know the path to this script to copy it.
- **Token Security:** The `UpdateService` must continue to use **DPAPI (CurrentUser)** to encrypt/decrypt the GitHub Device Flow tokens, ensuring security is maintained during the refactor.
- **User data backup/restore:** Preserve the current behavior of backing up `logs`, `reports`, and `config.txt` to `%LOCALAPPDATA%\DONUT\UserData` before installs and restoring them on launch if hashes differ. This requires a backup responsibility (UpdateService or dedicated helper) plus a startup hook in the UI layer.
- **Hash-based worker copy:** Copy `InstallWorker.ps1` to `%LOCALAPPDATA%\DONUT` only when the SHA-256 differs, to avoid unnecessary writes.
- **Downloader hardening:** Keep SHA-256 verification of the MSI, HTML/SSO download guards, rollback when the latest tag is lower than installed, and silent reuse/refresh of stored Device Flow tokens.

### Packaging & Deployment (Visual Studio)
**Challenge:** The project was previously packaged using PowerShell Studio with specific settings (Windows Tray App engine, Admin rights, specific GUIDs). We are switching to Visual Studio Community edition for packaging, since it is free.

**Refactor Strategy:**
- **C# Wrapper (`Donut.Launcher`):**
    - **Type:** C# .NET 9.0 Windows Application (`<OutputType>WinExe</OutputType>`).
    - **Tray Functionality:** To match the "Windows Tray App" engine, the wrapper will implement `System.Windows.Forms.NotifyIcon`. This ensures the app runs in the background with a system tray icon, maintaining the original user experience.
    - **Manifest:** The application manifest will be configured to require `Administrator` privileges (`<requestedExecutionLevel level="requireAdministrator" />`), matching the `AsAdmin=1` setting.
- **MSI Installer (Visual Studio Installer Project):**
    - **UpgradeCode:** We **MUST** use `{FD0DF01A-1A35-454C-AF08-5BE6B458C6A7}`. This tells Windows Installer that this new MSI is an upgrade to the existing DONUT application, allowing it to replace the old version seamlessly.
    - **ProductCode:** A new GUID will be generated for each version (e.g., 2.0.0).
    - **Architecture:** The installer will be targeted for **x64** (`Platform=64 Bit Package`).
    - **Scope:** Per-Machine installation (`AllUsers=1`).

### UI & Threading
**Challenge:** WPF UI updates must happen on the UI thread.

**Refactor Strategy:**
- **High-Frequency Updates (Logs):** As decided in the "Parallel Execution" section, we will use a **Polling Pattern** for logs. The View (or Controller) will use a `DispatcherTimer` to drain the thread-safe queue and update the UI in batches. This prevents UI freezing caused by flooding the Dispatcher with individual event invocations.
- **State Changes (Events):** To avoid any direct interference from background threads (which caused freezing issues in the past), we will **not** use `Dispatcher.Invoke` or `BeginInvoke`. Instead, state changes (e.g., `ScanStarted`, `ScanCompleted`) will update a thread-safe state object or queue. The same `DispatcherTimer` used for logs will poll this state and update the UI controls (buttons, status bars) on the next tick.
- **ApplyUpdates two-phase flow:** Mirror the existing behavior: temporary scan config -> run scan -> copy report XML -> gather remote driver/app data via PsExec -> brand-based driver/app matching -> per-host confirmation popup (skip apply if not confirmed) -> skip apply when no updates are found -> copy updates list to clipboard.
- **Manual reboot detection:** Parse log lines for reboot-required vs auto-reboot; surface a completion popup listing machines needing manual reboot. Pre-seed the manual reboot list when config flags disable automatic reboot (`reboot`/`forceRestart`).
- **Multi-device safety prompt:** If ApplyUpdates is enabled and multiple hosts are queued, show a single confirmation listing all targets before enqueueing runspaces.

### Configuration & Persistence
**Challenge:** `config.txt` and `WSID.txt` persistence.

**Refactor Strategy:**
- **JSON Migration:** Both `config.txt` and `WSID.txt` will be refactored into JSON format (`config.json` and `wsid.json`) to support common standards.
- **Consolidation:** `WSID.txt` (currently in `res/`) will be moved to the `config/` folder as `wsid.json`. This centralizes all user-configurable data in one location.
- **ConfigManager:** This service will handle reading/writing both configuration files.
- **Preserve legacy config rules:** Enforce exactly one enabled main command, require `throttleLimit`, ignore blank values when building arguments, and keep flag handling for `silent`, `reboot`, `forceupdate`, `autoSuspendBitLocker`, etc., so generated command lines match the legacy behavior.

### PowerShell Constraints to Retain
- **Absolute script paths in runspaces:** Child runspaces must receive absolute script paths because `AddScript` rejects relative paths in the packaged build.
- **Window chrome for resize:** Use XAML `WindowChrome` with `AllowsTransparency="False"`, `WindowStyle="None"`, `ResizeMode="CanResize"`, and `WindowChrome.ResizeBorderThickness="6"` (or similar) to keep edge/corner resize without any P/Invoke.

---

## 3. Testing Strategy

The core principle for testing this new structure is **Dependency Injection**.

### The Problem: Side Effects
Code that directly touches the network or file system is hard to unit test.
```powershell
# Hard to test!
$ip = [System.Net.Dns]::GetHostAddresses($computer)[0]
```

### The Solution: The Wrapper Pattern
We create a class whose *only* job is to touch the network. We can then "mock" (fake) this class during tests.

#### 1. The Wrapper Class (`src/Services/NetworkProbe.ps1`)
```powershell
class NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.Dns]::GetHostAddresses($hostname)[0]
    }
}
```

#### 2. The Service Class (`src/Services/RemoteExecutionService.ps1`)
This service accepts a `NetworkProbe` in its constructor.
```powershell
class RemoteExecutionService {
    hidden $NetworkProbe
    RemoteExecutionService($probe) {
        $this.NetworkProbe = $probe
    }
    # ... uses $this.NetworkProbe.ResolveHost() ...
}
```

#### 3. The Pester Test (`tests/Unit/RemoteExecutionService.Tests.ps1`)
We create a **Mock** version of the probe that returns fake data.
```powershell
class MockNetworkProbe : NetworkProbe {
    [System.Net.IPAddress] ResolveHost([string]$hostname) {
        return [System.Net.IPAddress]::Parse("192.168.1.100")
    }
}

It "Successfully scans a valid device" {
    $fakeProbe = [MockNetworkProbe]::new()
    $service = [RemoteExecutionService]::new($fakeProbe)
    $result = $service.ScanDevice("Valid-PC")
    $result | Should -Be "Success: 192.168.1.100"
}
```

### Summary of What to Test
| Component | What to Test | How to Mock |
| :--- | :--- | :--- |
| **Models** | Properties, simple validation. | No mocking needed. |
| **Services** | Logic, error handling. | Mock `NetworkProbe`, `FileSystem`, `PsExecWrapper`. |
| **Controllers** | UI flow (e.g., "Did clicking Scan call the Service?"). | Mock the `Service` class. |
| **Wrappers** | The actual .NET/exe calls. | **Don't unit test these.** Use Integration tests. |

### Test Structure
- **Unit (tests/Unit):**
  - Config parsing/build (one enabled command, throttle required, blank args ignored, flag handling).
  - Service logic with mocks (`NetworkProbe`, `PsExecWrapper`, file system): scan/apply two-phase orchestration, driver matching, confirmation triggers.
  - UpdateService token/decision logic with mocked GitHub API.
- **Integration (tests/Integration):**
  - Remote execution paths (DNS failure, Reverse-DNS mismatch, RPC 1722) with a mock/loopback target and temp UNC folders to verify log/report copy.
  - ApplyUpdates flow using report XML + fake driver/app data to assert confirmation/skip and clipboard list generation.
  - Updater flow: SHA-256 verification, HTML/SSO rejection, rollback when remote < local, hash-based worker copy, backup/restore of logs/reports/config across install simulation.
  - Backup/restore persistence: Run backup then restore into a fresh temp tree and compare hashes for logs/reports/config.
