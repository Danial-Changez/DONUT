
# Automated Remote Dell Command Update

This PowerShell script automates the remote execution of the Dell Command Update (DCU) CLI tool across multiple Dell computers in a network. It uses parallel processing and configuration-driven commands to simplify update execution remotely.

## Table of Contents
- [Automated Remote Dell Command Update](#automated-remote-dell-command-update)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Prerequisites](#prerequisites)
    - [Required Tools](#required-tools)
      - [Installation Steps:](#installation-steps)
  - [Usage](#usage)
    - [Steps to Run](#steps-to-run)
  - [Example Configuration](#example-configuration)
  - [Future Enhancements](#future-enhancements)
  - [Known Issues \& Additional Notes](#known-issues--additional-notes)

---

## Features

1. **Remote DCU Execution**:
   - Executes Dell Command Update CLI remotely on Dell computers over the network.

2. **Parallel Execution**:
   - Uses PowerShell's parallel execution capability for fast, concurrent updates.

3. **Dynamic Configuration**:
   - Driven by user-friendly configuration files (`config.txt`) for flexible adjustments.

4. **Detailed Logging**:
   - Generates detailed logs for each host, recording execution outcomes and errors for easy debugging.

5. **DNS and Error Validation**:
   - Validates DNS records and IP assignments before executing commands to ensure accurate targeting.

---

## Prerequisites

### Required Tools

- **PowerShell 7**  
  Necessary for parallel processing capabilities.

- **Dell Command Update CLI (`dcu-cli.exe`)**  
  Must be installed on each target computer.

- **PsExec (Sysinternals Suite)**  
  Enables remote command execution.

  #### Installation Steps:
  1. Download PsExec from [Sysinternals Official Site](https://learn.microsoft.com/en-us/sysinternals/downloads/psexec).
  2. Extract and place `PsExec.exe` in a system `PATH` directory, such as `C:\Windows\System32`.

---

## Usage

### Steps to Run

**Step 1: Configure Commands (`config.txt`)**
- Ensure only **one** command option is set to `enable` at any time; all others should be `disable`.
- Set arguments clearly or leave blank if not applicable.
  - Argument ignored example:
    ```plaintext
    - updateType =
    ```
  - Argument accepted example:
    ```plaintext
    - updateType = bios,others
    ```
- Reference the [DCU-CLI Documentation](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-%7C-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us) for additional commands.

**Note**:  
Currently, only the `outputLog` parameter is automatically collected locally. Logs defined as `.xml` or other attributes must be retrieved manually.

**Step 2: List Target Computers**
- Populate `res/WSID.txt` with computer hostnames, one per line.

**Step 3: Execute Script**
- From Admin PowerShell, run:
  ```powershell
  ./src/remoteDCU.ps1
  ```

**Step 4: Monitor Execution**
- Terminal output displays progress and errors in real-time.
- Detailed logs are located within the `logs/` directory.

---

## Example Configuration

Default `config.txt` provided; sample configurations below for clarity:

**Simple update config:**
```plaintext
applyUpdates = enable
- silent = enable
- reboot = enable

throttleLimit = 50
```

**Multiple commands template:**
(Only one main command should be enabled)
```plaintext
applyUpdates = disable
- silent = enable

scan = disable

driverInstall = disable

configure = disable
- updateType = firmware,driver,bios
- biosPassword =
- scheduleAction = DownloadAndNotify
- scheduleWeekly = Friday,00:00
- autoSuspendBitLocker = enable

help = disable

version = enable

throttleLimit = 5
```

---

## Future Enhancements

1. **Graphical User Interface (GUI)**  
   Explore implementation using frameworks like CustomTkinter for user-friendly interactions.

2. **Enhanced Error Recovery**  
   Introduce retries and state checks to recover from dropped connections or interrupted updates (common with network driver installs).

---

## Known Issues & Additional Notes

1. **BIOS Update Issues:**
      - Some Dell models do not receive the latest BIOS updates via DCU CLI:
        - **Latitude 5330**: Updates only to BIOS v1.24.0 (latest v1.27.0 at the time of writing).
        - **Latitude 7490**: Updates only to BIOS v1.41.0 (latest v1.42.0 at the time of writing).

      - Certain BIOS updates may fail and require manual installation.

      **Current Update Failures Identified For:**
      - Latitude 5340
      - Latitude 3390

      These issues stem from limitations in Dell's DCU CLI tool itself rather than the automation script.

2. **Limited to Remote Computers:**
    - **Designed for Remote Use Only:**

      This script is intended to execute remotely and relies on retrieving the host address of remote machines.
  
    - **Local Host Limitation:**

      Executing the script on the local host will cause unexpected behaviour. It attempts to resolve and pass every host address associated with the machine, which can lead to errors or script failure.

