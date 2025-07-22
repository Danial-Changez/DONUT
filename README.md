# DONUT

This PowerShell project automates remote execution of the Dell Command Update (DCU) CLI tool across multiple Dell computers in a network. It uses parallel processing and configuration-driven commands for remote updates.

---

## Table of Contents
- [DONUT](#donut)
  - [Table of Contents](#table-of-contents)
  - [Features](#features)
  - [Prerequisites](#prerequisites)
  - [Usage](#usage)
    - [Steps to Run](#steps-to-run)
  - [Developer Guide](#developer-guide)
    - [Project Structure](#project-structure)
    - [Getting Started](#getting-started)
    - [Key Concepts](#key-concepts)
    - [Extending the Project](#extending-the-project)
    - [Testing](#testing)
  - [Example Configuration](#example-configuration)
  - [Future Enhancements](#future-enhancements)
  - [Known Issues \& Additional Notes](#known-issues--additional-notes)
  - [Contributing](#contributing)

---

## Features

- **Remote DCU Execution:** Runs Dell Command Update CLI remotely on networked Dell computers.
- **Parallel Execution:** Uses PowerShell runspaces for parallel updates.
- **Dynamic Configuration:** Driven by user-friendly configuration files (`config.txt`).
- **Detailed Logging:** Per-host logs for execution outcomes and errors.
- **DNS and Error Validation:** Validates DNS/IP before execution.

---

## Prerequisites

- **PowerShell 7+** (required for parallel processing, current project runs on 7.5.2)
- **Dell Command Update CLI (`dcu-cli.exe`)** (must be installed on each target)
- **PsExec (Sysinternals Suite)** (for remote command execution)
- **.NET Desktop 9.0+** (needed for WPF to run with the current packaged version)
---

## Usage

### Steps to Run

1. **Launch the Application:**
   - Open app through the Start Menu.
   - Apply any updates if prompted (unless specificed otherwise by Team).  

2. **Configure Commands:**
   - Use the Config tab in the UI to select and configure DCU commands and options.
   - For more information on "Text Option" parameters, select the Help option from Config and use TPS5330AP as the target machine.
   - See [DCU-CLI Documentation](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-%7C-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us) for more details.

3. **List Target Computers:**
   - Enter WSID's in the search bar, separated by commas or new lines.
   - The UI will display a tab for each computer and manage the queue automatically.

4. **Run and Monitor:**
   - Click the search button (button with command name, i.e **ApplyUpdates**, **Scan**, etc) to start remote updates.
   - Progress and logs are shown in real time in each computer's tab.
   - Manual reboot prompts and update confirmations are handled via popups in the UI.

    **Note: If you disconnect from the network while updates are running, they will continue, you will just lose live feed.**

5. **Review Logs:**
   - Detailed logs are saved in the logs tab for each run.
   - If a file path is specificed in "Output Log", a tab in its name will be appended to under the Logs page.
   - If no file path is specified, "Default" tab, or the last command specific will be appended to.
     - For example if the "Output Log" was last set to `C:\temp\dcuLogs\applyUpdates.log`, new data will be appended to ApplyUpdates tab.

---

## Developer Guide

### Project Structure

- `src/` — Main PowerShell modules and scripts
  - `MainWindow.ps1` — Main WPF UI logic
  - `Updater.ps1` — Update logic and manifest handling
  - `remoteDCU.ps1` — Remote execution logic
  - Supporting modules: `ConfigView.psm1`, `Helpers.psm1`, `ImportXaml.psm1`, `LogsView.psm1`, `Read-Config.psm1`
- `Views/` — XAML files for WPF UI
  - `Config Options/` — All Config tab dropdown pages
  - `PopUp.xaml` — UI for finished threads pop up
  - `Update.xaml` — UI for updater
  - `Confirmation.xaml` — UI for Apply Updates confirmation
- `Styles/` — XAML style resources
  - `UIColors.xaml` — Centralized UI colors
  - `Icons.xaml` — Icon geometry data
  - `ModernControls.xaml` — Custom controls for textboxes, checkboxes, comboboxes, etc.
  - `ButtonStyles.xaml` — Sidebar UI controls
- `Images/` — UI assets
- `res/` — Host list (`WSID.txt`) and other resources
- `logs/` — Log file target directory
- `reports/` — XML file target directory
- `Startup.pss` — Entry point for Updater.ps1 and MainWindow.ps1

### Getting Started

1. **Clone the repository** and open in VS Code or PowerShell Studio.
2. **Install dependencies** (see Prerequisites).
3. **Review configuration files** (`config.txt`, `WSID.txt`) and XAML UI files in `Views/` and `Styles/`.
4. **For packaging, use PowerShell Studio's packager to build the MSI/executable.**
   - All new modules or script files should be called within `MainWindow.ps1`, so we should never have to repackage with PowerShell Studio.
   - Update file paths in `Manifest-Generator.ps1` as needed.

### Key Concepts

- **Runspaces:** Used for parallel remote execution. See `MainWindow.ps1` for runspace management and UI updates.
- **WPF UI:** All user interaction is via the XAML-based interface. UI logic is in `MainWindow.ps1` and supporting modules.
- **Execution Policy:** Set to `Bypass` in `Startup.pss` for development and packaging convenience.
- **Manifest Generation:** See `Manifest-Generator.ps1` for file hashing and signing.

### Extending the Project

- **Add new commands:** Update `ConfigView.psm1`, related XAML files, and UI event handlers.
- **UI changes:** Edit XAML files in `Views/` and `Styles/`, and update event logic in `MainWindow.ps1`.
- **Deploying Changes:**
  - Add updated files in the correct directory (e.g., `src/MainWindow.ps1`, `Styles/Icons.xaml`).
  - Update `$Files` parameter in `Manifest-Generator.ps1`.
  - Increment `$Version`.
  - Run the manifest generator script to update the manifest.

### Testing

- Use test hostnames in `WSID.txt` or the UI search bar.
- Review logs in `logs/` and UI tabs for troubleshooting.
- Use PowerShell Studio's debugger for step-through UI and script logic. UI events and runspaces can be debugged interactively.

---

## Example Configuration

See `config.txt` for templates. Only one main command should be enabled.

```plaintext
applyUpdates = enable
- silent = enable
- reboot = enable

throttleLimit = 50
```

---

## Future Enhancements

- **GUI Improvements:** More user-friendly controls, better error dialogs.
- **Advanced Error Recovery:** Retries, state checks for interrupted updates.
- **Cross-platform Support:** Investigate compatibility with PowerShell Core on Linux/Mac.

---

## Known Issues & Additional Notes

- **BIOS Update Limitations:** Some Dell models may not receive the latest BIOS via DCU CLI.
- **Manual Reboots:** Some updates require manual intervention; see logs and reboot queue.
- **Remote Only:** Designed for remote execution; local runs may behave unexpectedly.

---

## Contributing

- Fork and submit pull requests for improvements.
- Open issues for bugs or feature requests.
- Follow PowerShell best practices and comment your code.

---