<h1> DONUT </h1>

This PowerShell project automates remote execution of the Dell Command Update (DCU) CLI tool across multiple Dell computers in a network. It uses parallel processing and configuration-driven commands for remote updates. Please note that the current version has been refactored in accordance with the [Refactored Proposal](docs/Refactoring_Proposal.md). Refer to it for more details.

---

<h2> Table of Contents </h2>

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
  - [Installation](#installation)
  - [Steps to Run](#steps-to-run)
- [Developer Guide](#developer-guide)
  - [Getting Started](#getting-started)
  - [Key Concepts](#key-concepts)
- [Contributing](#contributing)
- [Additional Notes](#additional-notes)

---

## Features

- **Remote DCU Execution:** Runs Dell Command Update CLI remotely on networked Dell computers.
- **Parallel Execution:** Uses PowerShell runspaces for parallel updates, with each computer being assigned its own tab.
- **Dynamic Configuration:** Driven by user-friendly configuration files (`config.txt`).
- **GitHub App Updates:** Authenticates via a GitHub App (Device Flow) and self-updates from the latest GitHub release (supports rollback by tag).
- **Detailed Logging:** Per-host logs for execution outcomes and errors.
- **DNS and Error Validation:** Validates DNS/IP before execution.

---

## Prerequisites

- **PowerShell 7+** (required for parallel processing, current project runs on 7.5.2)
- **Dell Command Update CLI (`dcu-cli.exe`)** (must be installed on each target)
- **PsExec (Sysinternals Suite)** (for remote command execution)
- **.NET Desktop 9.0+** (needed for WPF to run with the current packaged version)
- **Windows Admin Access** (for remote access)
- **GitHub App Access** (to allow your team to sign in via Device Flow and receive updates from your org's GitHub Releases)

---

## Usage

### Installation

1. All [Prerequisites](#prerequisites) must be installed or acquired before using DONUT.
2. Review Step 2 to set up PsTools, otherwise skip to Step 3 if already installed.
   - PsTools is available at `https://learn.microsoft.com/en-us/sysinternals/downloads/pstools`.
   - Extract the zip to **Documents**, **Downloads**, or **Desktop** (any one of these directories will suffice).
   - Transfer the **contents** of the folder to `C:\Windows\System32`.
3. Run the .NET Desktop SDK installer (available at `https://dotnet.microsoft.com/en-us/download/dotnet/9.0`).
4. Install DONUT (MSI available under releases).
5. Navigate to **Virus & Threat Protection > Manage Settings > Add or remove exclusions** (this is NOT a virus, just not digitally signed).
6. Click **Add an exclusion**.
7. Select **Folder**.
8. Enter `C:\Program Files\Bakery\DONUT`.

### Steps to Run

1. **Launch the Application:**

   - Open the app through the Start Menu.
   - On first launch (or if the token expired), sign in with your GitHub App using the device code prompt so the updater can pull releases.
   - Apply any updates if prompted (unless specified otherwise by the team).

2. **Configure Commands:**

   - Use the Config tab in the UI to select and configure DCU commands and options.
   - For more information on "Text Option" parameters, see [DCU-CLI Documentation](https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/dell-command-%7C-update-cli-commands?guid=guid-92619086-5f7c-4a05-bce2-0d560c15e8ed&lang=en-us) for more details.

     **Note: If a main command is run with no options from the `Dropdown/Multi-Select Options` selected, then DCU will use the target machine's defaults.**

3. **List Target Computers:**

   - Enter the target hostname(s) in the search bar, separated by commas or new lines.
   - The UI will display a tab for each computer and manage the queue automatically.

4. **Run and Monitor:**

   - Click the search button (button with command name, i.e., **ApplyUpdates** or **Scan**) to start.
   - Progress and logs are shown in real time in each computer's tab.
   - Manual reboot prompts and update confirmations are handled via popups in the UI.

   **Note: If you disconnect from the network while updates are running, they will continue, you will just lose access to the live feed.**

5. **Review Logs:**
   - Detailed logs are saved in the logs tab for each run (if specified).
   - If a file path is specified in "Output Log", a tab in its name will be appended under the Logs page.
   - If no file path is specified, the "Default" tab will be appended to if any errors with the run are detected.
     - For example, if the "Output Log" was set to `C:\temp\DONUT\applyUpdates.log`, new data will be appended to the ApplyUpdates tab.

---

## Developer Guide

### Getting Started

1. **Clone the repository** and open in VS Code or PowerShell Studio.
2. **Install dependencies** (see [Prerequisites](#prerequisites)).
3. **Review configuration files** and XAML UI files in `Views/` and `Styles/`.
4. **Package and publish updates via GitHub Releases.**
   - Build the MSI with Visual Studio's packager (set the Product Version to your release tag).
   - Create a GitHub release with that tag and upload the MSI asset (matches `MsiAssetPattern`, default `*.msi`).
   - The app authenticates via your GitHub App (Device Flow), compares the installed version to the latest release tag, and self-updates or rolls back accordingly.

### Key Concepts

- **Runspaces:** Used for parallel remote execution, runspace management, and UI updates.
- **WPF UI:** All user interaction is via the XAML-based interface and supporting presenter modules.
- **Execution Policy:** Set to `Bypass` in `Startup.pss` for development and packaging convenience.
- **GitHub App Updates:** Requests a GitHub Device Flow token, fetches the latest release, verifies the MSI SHA-256.

## Contributing

- **UI Changes:** Edit XAML files in `Views/` and `Styles/`.
- **Logic Changes:** Update event logic in the respective `Core/` or `Service/` directories, with each page's supporting function(s) in its relevant module file.
- **Deploying Changes:**
  - Build a new MSI in PowerShell Studio (update the Product Version).
  - Draft a GitHub release with a tag matching that version and upload the MSI asset (honor `MsiAssetPattern` if you rename it).
  - Org admins sign in once via the GitHub App; the app will pick up the latest release on startup and prompt users to update or roll back based on the tag.
- **Optional:**
  - Repackage the project in PowerShell Studio with the new version (i.e., 1.0.0.4) and build the MSI.
  - Keep a copy of the MSI on the internal file share for manual installs or recovery.

---

## Additional Notes

- **Remote Only:** Designed for remote execution; local runs can behave unexpectedly.

---
