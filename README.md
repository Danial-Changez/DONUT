<h1> DONUT </h1>

This PowerShell project automates remote execution of the Dell Command Update (DCU) CLI tool across multiple Dell computers in a network. It uses parallel processing and configuration-driven commands for remote updates.

---

<h2> Table of Contents </h2>

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Installation](#installation)
  - [Steps to Run](#steps-to-run)
- [Developer Guide](#developer-guide)
  - [Project Structure](#project-structure)
  - [File Explanations](#file-explanations)
  - [Getting Started](#getting-started)
  - [Key Concepts](#key-concepts)
  - [Testing](#testing)
- [Configuration File Logic](#configuration-file-logic)
  - [Command Selection](#command-selection)
  - [Configuration Example](#configuration-example)
  - [Parameter Handling](#parameter-handling)
  - [Required Settings](#required-settings)
  - [How It Works](#how-it-works)
- [Future Improvements](#future-improvements)
- [Bugs](#bugs)
- [Contributing](#contributing)
- [Additional Notes](#additional-notes)

---

## Features

- **Remote DCU Execution:** Runs Dell Command Update CLI remotely on networked Dell computers.
- **Parallel Execution:** Uses PowerShell runspaces for parallel updates, with each computer being assigned its own tab.
- **Dynamic Configuration:** Driven by user-friendly configuration files (`config.txt`).
- **Detailed Logging:** Per-host logs for execution outcomes and errors.
- **DNS and Error Validation:** Validates DNS/IP before execution.

---

## Prerequisites

- **PowerShell 7+** (required for parallel processing, current project runs on 7.5.2)
- **Dell Command Update CLI (`dcu-cli.exe`)** (must be installed on each target)
- **PsExec (Sysinternals Suite)** (for remote command execution)
- **.NET Desktop 9.0+** (needed for WPF to run with the current packaged version)
- **Windows Admin Access** (for remote access)
- **TPSFiles Share** (needed for access to the manifest)

---

## Usage

### Installation

1. All [Prerequisites](#prerequisites) must be installed or acquired before using DONUT.
2. Review Step 2 to set up PsTools, otherwise skip to Step 3 if already installed.
   - PsTools is available at `\\cgic.ca\GPHFiles\TPSFiles\Support-Applications\DONUT\Production\PsTools`.
   - Copy the folder to **Documents**, **Downloads**, or **Desktop** (any one of these directories will suffice).
   - Transfer the **contents** of the folder to `C:\Windows\System32`.
3. Run the .NET Desktop runtime installer (MSI available in `DONUT\Production`).
4. Install DONUT (MSI available in `DONUT\Production`).
5. Navigate to **Virus & Threat Protection > Manage Settings > Add or remove exclusions** (this is NOT a virus, just not digitally signed).
6. Click **Add an exclusion**.
7. Select **Folder**.
8. Enter `C:\Program Files\Bakery\DONUT`.

### Steps to Run

1. **Launch the Application:**

   - Open the app through the Start Menu.
   - Apply any updates if prompted (unless specified otherwise by the team).

2. **Configure Commands:**

   - Use the Config tab in the UI to select and configure DCU commands and options.
   - For more information on "Text Option" parameters, see [DCU-CLI Documentation](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-%7C-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us) for more details.

     **Note: If a main command is run with no options from the `Dropdown/Multi-Select Options` selected, then DCU will use the target machine's defaults.**

3. **List Target Computers:**

   - Enter WSID(s) in the search bar, separated by commas or new lines.
   - The UI will display a tab for each computer and manage the queue automatically.

4. **Run and Monitor:**

   - Click the search button (button with command name, i.e., **ApplyUpdates** or **Scan**) to start.
   - Progress and logs are shown in real time in each computer's tab.
   - Manual reboot prompts and update confirmations are handled via popups in the UI.

   **Note: If you disconnect from the network while updates are running, they will continue, you will just lose access to the live feed.**

5. **Review Logs:**
   - Detailed logs are saved in the logs tab for each run (if specified).
   - If a file path is specified in "Output Log", a tab in its name will be appended under the Logs page.
   - If no file path is specified, "Default" tab will be appended to if any errors with the run were detected.
     - For example, if the "Output Log" was set to `C:\temp\DONUT\applyUpdates.log`, new data will be appended to the ApplyUpdates tab.

---

## Developer Guide

### Project Structure

```
📦DONUT
 ┣ 📂bin - DLL's and EXE
 ┃ ┗ 📂x64
 ┃ ┃ ┗ 📂DONUT
 ┃ ┃ ┃ ┣ 🍩DONUT.exe
 ┣ 📂Images - UI Assets
 ┃ ┣ 📷donut icon48x48.ico
 ┃ ┣ 🖼️logo purple arrow.png
 ┃ ┗ 🖼️logo yellow arrow.png
 ┣ 📂logs
 ┃ ┣ 🪵applyUpdates.log
 ┃ ┣ 🪵default.log
 ┃ ┗ 🪵scan.log
 ┣ 📂reports
 ┣ 📂res - Any Resources for Persistent Data
 ┃ ┗ 📄WSID.txt
 ┣ 📂src - PowerShell Modules and Scripts
 ┃ ┣ 🔧ConfigView.psm1
 ┃ ┣ 🔧Helpers.psm1
 ┃ ┣ 🔧ImportXaml.psm1
 ┃ ┣ 🔧LogsView.psm1
 ┃ ┣ 🔧Read-Config.psm1
 ┃ ┣ 📜MainWindow.ps1
 ┃ ┣ 📜remoteDCU.ps1
 ┃ ┗ 📜Updater.ps1
 ┣ 📂Styles - XAML Resource Dictionaries
 ┃ ┣ 🎨ButtonStyles.xaml
 ┃ ┣ 🎨Icons.xaml
 ┃ ┣ 🎨ModernControls.xaml
 ┃ ┗ 🎨UIColors.xaml
 ┣ 📂Views - XAML Window and Child Views
 ┃ ┣ 📂Config Options - All Config Child Views (only Scan.xaml and ApplyUpdates.xaml are active)
 ┃ ┃ ┣ 🎨ApplyUpdates.xaml
 ┃ ┃ ┣ 🎨Configure.xaml
 ┃ ┃ ┣ 🎨CustomNotification.xaml
 ┃ ┃ ┣ 🎨DriverInstall.xaml
 ┃ ┃ ┣ 🎨GenerateEncryptedPassword.xaml
 ┃ ┃ ┣ 🎨Help.xaml
 ┃ ┃ ┣ 🎨Scan.xaml
 ┃ ┃ ┗ 🎨Version.xaml
 ┃ ┣ 🎨ConfigView.xaml
 ┃ ┣ 🎨Confirmation.xaml
 ┃ ┣ 🎨HomeView.xaml
 ┃ ┣ 🎨LogsView.xaml
 ┃ ┣ 🎨MainWindow.xaml
 ┃ ┣ 🎨PopUp.xaml
 ┃ ┗ 🎨Update.xaml
 ┣ 🚫.gitignore
 ┣ ⚙️config.txt
 ┣ 💠DONUT.psproj
 ┣ 💠DONUT.psproj.psbuild
 ┣ 💠DONUT.psprojs
 ┗ 💠Startup.pss
 ┣ 📖README.md - Documentation
```

### File Explanations

- `src/`
  - `MainWindow.ps1` — Main WPF UI logic handling events, runspace management, etc.
  - `Updater.ps1` — Update logic and manifest handling
  - `remoteDCU.ps1` — Remote execution logic
  - Supporting modules: `ConfigView.psm1`, `Helpers.psm1`, `ImportXaml.psm1`, `LogsView.psm1`, `Read-Config.psm1`
- `Views/`
  - `Config Options/` — All Config tab dropdown pages (Only Scan.xaml and ApplyUpdates.xaml are active)
  - `HomeView.xaml` — UI for Home page
  - `ConfigView.xaml` — UI for Config page
  - `LogsView.xaml` — UI for Logs page
  - `PopUp.xaml` — UI for finished threads popup
  - `Update.xaml` — UI for update popup
  - `Confirmation.xaml` — UI for confirmation popups (i.e., manual reboot and apply updates popups)
- `Styles/`
  - `UIColors.xaml` — UI colors dictionary
  - `Icons.xaml` — Icon geometry data
  - `ModernControls.xaml` — Custom controls for textboxes, checkboxes, comboboxes, etc.
  - `ButtonStyles.xaml` — Sidebar button styles
- `res/`
  - `WSID.txt` — Stores all WSID(s) updated through search bar
- `logs/` — Log file target directory
- `reports/` — XML file target directory
- `config.txt` — Config file that determines the settings of remote command run
- `.gitignore` — Any files that need to be ignored
- `Startup.pss` — Entry point for Updater.ps1 and MainWindow.ps1 (Code for EXE)

### Getting Started

1. **Clone the repository** and open in VS Code or PowerShell Studio.
2. **Install dependencies** (see [Prerequisites](#prerequisites)).
3. **Review configuration files** (`config.txt`, `WSID.txt`) and XAML UI files in `Views/` and `Styles/`.
4. **For packaging, use PowerShell Studio's packager to build the MSI/executable.**
   - All new modules or script files should be called within `MainWindow.ps1`, so we should never have to redistribute the app.
   - Update file paths in `Manifest-Generator.ps1` and version as needed.
   - Run it to generate a new manifest to push updates.

### Key Concepts

- **Runspaces:** Used for parallel remote execution. See `MainWindow.ps1` for runspace management and UI updates.
- **WPF UI:** All user interaction is via the XAML-based interface. UI logic is in `MainWindow.ps1` and supporting modules.
- **Execution Policy:** Set to `Bypass` in `Startup.pss` for development and packaging convenience.
- **Manifest Generation:** Use `Manifest-Generator.ps1` for version updates.

### Testing

- Use lab machines for testing changes before deployment.
- Review log tabs for any errors needing troubleshooting.

---

## Configuration File Logic

The `config.txt` file controls which DCU command will be executed and its parameters. The configuration follows these rules:

### Command Selection

- **Only one main command** can be set to `enable` at any time; all others must be set to `disable`.
- Available commands: `scan`, `applyUpdates`, `configure`, `customnotification`, `driverInstall`, `generateEncryptedPassword`, `help`, `version`
  - Only `scan` and `applyUpdates` are available in the UI after leadership discussion.

### Configuration Example

```plaintext
scan = disable
applyUpdates = enable
  - silent = enable
  - reboot = enable
  - autoSuspendBitLocker = disable
  - forceupdate = disable
configure = disable
customnotification = disable
driverInstall = disable
generateEncryptedPassword = disable
help = disable
version = disable
throttleLimit = 5
```

### Parameter Handling

- **Blank parameters are ignored:** If a parameter value is left empty, it will not be passed to the DCU command.

  **Ignored example:**

  ```plaintext
  - updateType =
  ```

  **Applied example:**

  ```plaintext
  - updateType = Bios,Others
  ```

### Required Settings

- **throttleLimit:** Must always be declared. This controls how many computers can run the command simultaneously.

### How It Works

1. The application reads `config.txt` on startup
2. Validates that only one main command is enabled
3. Builds the DCU command string based on enabled parameters
4. Executes the command remotely on each target computer using the specified throttle limit

## Future Improvements

- **🟡 Versioning:** Update versioning work note to include application current versions as well.
  - Increase speed as well (currently takes 10-20 seconds to complete).
- **🟡 Failed Update Prompt:** Prompt for failed updates with hyperlinks to the specific driver page.
- **❌ Set Output Log as Default:** Set as a default whenever Scan or ApplyUpdates is chosen in Config.
  - Note: Preliminary scan for Apply Updates has this already.
- **❌ Change Tab Name to WSID if IP is Passed (Low Priority):** Use the System.Net.DNS library to extract hostName and set it as the tab name if an IP is passed instead of WSID.
- **❌ Battery Report Page (Low Priority):** TBD
- **❌ Add a Loading Bar for the Preliminary Scan (Low Priority):** TBD

**Note: Low Priority = Tasks for Lola and Daniel**

## Bugs

- **✅ Resize Logic Crash:** Possible workaround, set CanResize to CanResizeWithGrip.
  - Note: Only happens with packaged version, not with the script itself.
- **✅ Report Folder not Generating:** PowerShell Studio will not package the folder if it is empty.
  - Solution: Had MainWindow.ps1 check if the report folder exists, otherwise creats it on startup.
- **✅ Versioning Logic Can't Accept IP's:**
  - IP's need to be part of the "TrustedHosts list" if using WinRM.
  - Solution: Changed Protocol to fallback on DCOM if necessary.
  - Alternative: Can temporarily add the IP to the TrustedHosts list, then remove it at the end of the process.

---

## Contributing

- **UI Changes:** Edit XAML files in `Views/` and `Styles/`.
- **Logic Changes:** Update event logic in `MainWindow.ps1`, with each page's supporting function(s) in its relevant module file.
- **Deploying Changes:**
  - Navigate to `\\cgic.ca\GPHFiles\TPSFiles\Support-Applications\DONUT\Development`
  - Add updated files in the correct directory format (i.e., `src/MainWindow.ps1`, `Styles/Icons.xaml`).
  - These should mirror the relative file paths in your project directory.
  - Update `$Files` parameter in `Manifest-Generator.ps1`.
  - Increment `$Version`.
  - Run the manifest generator script to update the manifest.
  - Users will be prompted for updates on next app startup.
- **Optional:**
  - Repackage the project in PowerShell Studio with the new version (i.e., 1.0.0.4) and build the MSI.
  - Replace the old MSI in the file share with the new package.

---

## Additional Notes

- **Remote Only:** Designed for remote execution; local runs may behave unexpectedly.

---
