# Plan: Autostart (elevated), System Tray, and Global Hotkey

Implementation handoff. Self-contained: everything needed is in this file plus the
referenced sources. Work the steps in order — each lands green (format + lint + tests)
and is committed on its own before the next begins.

## 1. Goal

Three user-visible features, all opt-in via Settings:

1. **Start with Windows (as admin).** A toggle registers a per-user Task Scheduler task
   (`-RunLevel Highest`, logon trigger) so DONUT starts elevated at logon with no UAC
   prompt, minimized to the tray. Toggle off unregisters it.
2. **Functional tray icon.** DONUT lives in the system tray: left-click or menu "Open"
   shows/restores the window; menu "Exit" fully quits. Optional "close to tray" setting
   makes the X button hide instead of exit (default off — current behavior unchanged).
3. **Global hotkey.** A configurable key combo (default `Ctrl+Alt+D`) shows/restores the
   window from anywhere, including while hidden in the tray.

## 2. Decisions already made (do not re-litigate)

- **Autostart mechanism: Scheduled Task**, never an HKCU Run key (Run keys cannot start
  elevated; a `highestAvailable` manifest would UAC-prompt every logon). Per-user task
  named `DONUT-<username>`. Registering requires elevation; DONUT already runs elevated
  (PsExec requirement), so the toggle just works — failure is caught and toasted.
- **Hotkey mechanism: `RegisterHotKey`/`UnregisterHotKey` from user32.dll. HARD SECURITY
  CONSTRAINT:** do NOT use `SetWindowsHookEx` (any WH_KEYBOARD variant),
  `GetAsyncKeyState`/`GetKeyState` polling, or Raw Input (`RegisterRawInputDevices`).
  Those observe the global keystroke stream and trip AV/EDR keylogger heuristics — the
  entire reason RegisterHotKey was chosen. If a requirement seems to need a hook, stop
  and ask the user instead.
- **One tray icon, owned by the WPF UI thread** (PS-side `TrayPresenter`), replacing the
  launcher's current icon. Works identically on the dev path (`Start-Donut.ps1`) and in
  prod (`Donut.Launcher.exe`); no cross-thread marshalling to show the window.
- **Defaults:** hotkey `Ctrl+Alt+D` (setting may be blanked to disable); `closeToTray`
  off; task scope per-user. Win-modifier combos are allowed but not the default.

## 3. Current-state map (verified 2026-07-17)

- `src/Start-Donut.ps1` — dev/prod-hosted entry. Has a pwsh7+STA relaunch guard that
  forwards `@args`; compiles C# helpers via guarded `Add-Type` blocks (`Donut.Mvvm.*`,
  `Donut.Qr.QrCode` pattern). **No `param()` block today** — adding one changes `@args`
  forwarding (see step 2).
- `src/Launcher/Program.cs` — prod entry. `Main()` (no args today) shows `SplashForm` on
  the main thread, runs the PS/WPF app on a background STA thread (script path from the
  self-extracted tree under `%ProgramData%\DONUT\app`), and keeps the main thread in
  `Application.Run(new TrayApplicationContext())` — a NotifyIcon with an Exit-only menu.
  `StartupProgress.Post` drops reports when the splash handle was never created, so
  "skip splash" = construct it but never call `splash.Show()`.
- `src/Scripts/DonutApp.ps1` — builds the graph; `$updatePresenter.CheckAndPrompt()`
  (sign-in + update dialogs) runs BEFORE `$mainPresenter.Show()`. `using module` list is
  parse-order-sensitive (dependency order).
- `src/UI/Presenters/MainPresenter.psm1` — `Show()` calls
  `[Application]::Current.Run($this.Window)`; `ShutdownMode` is already
  `OnExplicitShutdown`. `Add_Closed` (~line 162) waits the Lens teardown then
  `Environment.Exit(0)`. `Add_SourceInitialized` (~line 193) already grabs the HWND for
  `WindowChromeHelper.ConstrainMaximize`. `Add_ContentRendered` (~line 182) holds the
  bring-to-front trick (Activate + Topmost toggle) — extract and reuse it.
- `src/Models/AppConfig.psm1` — `static $Defaults` + typed getters (`GetThrottleLimit`
  is the pattern: tolerate string forms, fall back to default). Settings persist via
  `ConfigManager.SaveConfig` to `%LOCALAPPDATA%\DONUT\config.json`.
- `src/UI/Views/Config Options/ConfigureOptionView.xaml` — where general settings are
  edited (`x:Name="throttleLimit"` TextBox ~line 840). Read `ConfigPresenter.psm1` to
  see how named controls are read/persisted on save and mirror it exactly.
- Icon asset: `assets/Images/donut icon48x48.ico` (sibling of `src/` both in the repo
  and in the prod extraction root; resolve via
  `Join-Path (Split-Path $config.SourceRoot -Parent) 'assets\Images\donut icon48x48.ico'`).
- `tools/Invoke-Lint.ps1` — TypeNotFound findings for runtime-compiled C# types are
  filtered BY NAME (`ObservableObject|RelayCommand|WindowChromeHelper|Donut\.Qr\.QrCode`).
- Tests: Pester 5 under `tests/Unit` (currently 523 green). Presenter tests fake
  collaborators with duck-typed classes (see `InventoryPresenter.Tests.Internal.ps1`).
- A PostToolUse hook auto-runs the matching unit test when a `src/{Core,Models,Services}`
  `.psm1` is edited, and a style hook enforces the comment rules on every edit.

## 4. Repo conventions and known traps (violating these fails hooks or crashes the app)

- **pwsh 7+ STA only**; never block the STA UI thread. All async work = pool jobs polled
  by `DispatcherTimer` (see FinderPresenter's poll timers).
- **Threadpool callbacks have no runspace.** Never pass a PS scriptblock as an async
  .NET callback (`BeginStop`, `RegisterWaitForSingleObject`, timers outside the
  dispatcher…) — it throws `PSInvalidOperationException` before the body runs and can
  crash the process (this exact bug froze search-during-scan; fixed in f71b993). Poll
  named handles/state from a DispatcherTimer instead. C# code may use real callbacks and
  raise .NET events; PS subscribes to those on the UI thread.
- **WPF handler scriptblocks rebind `$this` to the sender** — close over
  `$presenter = $this` (`.GetNewClosure()`), as every presenter does.
- **Comments:** why-not-what, one line preferred / two max, longer rationale goes in the
  file's `.NOTES` with `see .NOTES` inline. Comment-based help (`.SYNOPSIS`,
  `.DESCRIPTION`, `.NOTES`) on every new module/script. See `docs/Coding-Style.md`.
- **C# (`src/Launcher/`):** `#nullable enable`, XML `///` docs on public API only,
  no doc restating the identifier.
- **Gates before every commit:** `pwsh -File tools\Invoke-Format.ps1 -Check`,
  `pwsh -File tools\Invoke-Lint.ps1` (zero non-layout findings), full unit suite
  (`Invoke-Pester tests/Unit`) green.
- **Commits:** lowercase type-prefixed subject (`feat:`, `fix:`, `style:`…), body
  explains why; NO Claude co-author trailer, NO signing. One commit per step below.
- **Testing discipline:** every logic (non-UI) change ships with unit tests + a full
  regression run. UI-only wiring is covered by the manual checklist instead.

## 5. Implementation steps

### Step 0 — housekeeping: make the gates green at baseline

`Invoke-Format.ps1 -Check` currently fails on `src/Models/AppConfig.psm1` (assignment
alignment drift arrived with merge d317675; also 5 `PSAlignAssignmentStatement` lint
findings). Run `pwsh -File tools\Invoke-Format.ps1` (in-place), confirm lint drops to
layout-only findings, run the suite, and commit as `style: re-format AppConfig after
merge`. Nothing else in this commit.

### Step 1 — settings foundation (`feat: settings for autostart, tray, and hotkey`)

`src/Models/AppConfig.psm1`:
- `Defaults` additions: `startWithWindows = $false`, `closeToTray = $false`,
  `globalHotkey = 'Ctrl+Alt+D'`.
- Getters following the `GetThrottleLimit` tolerance pattern:
  - `[bool] GetStartWithWindows()` / `[bool] GetCloseToTray()` — accept `[bool]`, accept
    `'true'`/`'false'` strings case-insensitively, else default.
  - `[string] GetGlobalHotkey()` — trimmed string; empty/whitespace ⇒ `''` (disabled).

Tests (`tests/Unit/AppConfig.Tests.ps1`, extend): absent key ⇒ default; bool and string
forms; garbage ⇒ default; whitespace hotkey ⇒ disabled.

### Step 2 — tray icon + hidden start (`feat: functional tray icon and --tray start`)

**New `src/UI/Presenters/TrayPresenter.psm1`** (import from `MainPresenter.psm1` the way
`HomePresenter` imports `FinderPresenter`; keep `DonutApp.ps1`'s using-module order
valid). Owns:
- A `System.Windows.Forms.NotifyIcon` created on the WPF UI thread (the dispatcher pumps
  its messages; WinForms is already loaded). Icon from the asset path above, fallback
  `[System.Drawing.SystemIcons]::Application`. Tooltip "DONUT".
- Left-`MouseClick` ⇒ `ShowMainWindow()`. `ContextMenuStrip`: **Open**, separator,
  **Exit**.
- `ShowMainWindow()`: `Show()` the window, restore from Minimized, then the existing
  Activate/Topmost-toggle trick (extract that block from `Add_ContentRendered` into a
  shared `[void] BringToFront()` on MainPresenter and call it from both places). On first
  show after a hidden start, run the deferred update check (below) once.
- `ExitApp()`: set `$this.ExitRequested = $true`, then `Window.Close()` — the existing
  `Closed` teardown (Lens agent, hard exit) stays the single exit path.
- `Dispose()`: `Visible = $false`, dispose icon + menu. Called from the window's
  `Closed` handler BEFORE `Environment.Exit` (else the icon ghosts until hover).
- Close-to-tray: MainPresenter adds `Add_Closing`; when `GetCloseToTray()` and not
  `ExitRequested` ⇒ `$e.Cancel = $true`, hide window, one-time balloon tip
  ("DONUT is still running here — right-click to exit").

**Hidden start plumbing:**
- `Start-Donut.ps1`: add `param([switch]$Tray)` at the top. The relaunch guard must now
  forward parameters explicitly (a `param()` block empties `@args`): rebuild the child
  arg list from `$PSBoundParameters` (append `-Tray` when set).
- `Program.cs`: `Main(string[] args)`; `bool tray = args.Contains("--tray")`. When tray:
  construct the splash but never `Show()` it (StartupProgress then no-ops), and add an
  ISS variable `StartHidden = true` next to the existing `Splash` entry. Pass `--tray`
  through nothing else — the PS side reads the variable.
- `DonutApp.ps1`: `$hidden = [bool]$global:StartHidden -or $Tray` (the script itself has
  no params; read `$global:StartHidden` and, on the dev path, a `$global:TrayStart` set
  by `Start-Donut.ps1` from `-Tray`). When hidden: skip `CheckAndPrompt()` (record it as
  pending on MainPresenter via a property, e.g. `$mainPresenter.PendingUpdateCheck =
  $updatePresenter`) and call `$mainPresenter.ShowHidden()` instead of `Show()`.
- `MainPresenter.ShowHidden()`: run the dispatcher WITHOUT showing the window —
  `[System.Windows.Application]::Current.Run()` (no window argument; `MainWindow` is
  already assigned and `ShutdownMode` is `OnExplicitShutdown`, so nothing auto-shows or
  auto-quits). TrayPresenter is constructed and visible in both Show paths.
- **Launcher tray removal:** `TrayApplicationContext` loses its NotifyIcon and menu
  entirely (keep the class as the bare message-loop keeper, or swap to a plain
  `ApplicationContext`). The PS-side icon is now the only one.

**Single instance** (autostart makes double-launch routine):
- Names: mutex `Local\DONUT.SingleInstance`, event `Local\DONUT.ShowRequest`
  (AutoReset). Same names in both entries so dev/prod instances interact.
- `Program.cs` `Main` and `Start-Donut.ps1` (after the relaunch guard, so the guard's
  child doesn't false-positive against its parent — the parent `exit`s after spawning,
  but take no chances: acquire in the child only, i.e. below the guard): try to create
  the mutex; if it already exists ⇒ open the event, `Set()`, exit 0 silently.
- TrayPresenter polls the event with `WaitOne(0)` on a 500 ms DispatcherTimer (poll, not
  a wait-callback — see §4) and calls `ShowMainWindow()` when signaled.

Manual smoke this step: boot normally (window shows, tray icon present, Open/Exit work,
X honors `closeToTray` both ways), boot with `-Tray` (no window, no splash, icon there,
click restores, deferred sign-in/update prompt fires on first open), second launch while
running just foregrounds the first.

### Step 3 — global hotkey (`feat: global show/hide hotkey via RegisterHotKey`)

**New `src/Launcher/HotkeyManager.cs`** — `namespace Donut.Interop`, instance class:
- P/Invoke `RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk)` and
  `UnregisterHotKey(IntPtr hWnd, int id)` from user32 (`SetLastError = true`).
- `bool Attach(IntPtr hwnd, uint modifiers, uint vk)`: stores the hwnd, adds an
  `HwndSource.FromHwnd(hwnd)` hook (C# delegate — the per-message cost must not be a PS
  scriptblock), registers id `0x0D0` with `modifiers | MOD_NOREPEAT (0x4000)`. Returns
  false on failure; expose `int LastError` (`Marshal.GetLastWin32Error()`; 1409 =
  combo already taken).
- Hook: on `WM_HOTKEY (0x0312)` with matching id ⇒ raise `public event EventHandler?
  Pressed`. The hook runs on the UI thread, so a PS scriptblock subscribed via
  `add_Pressed` is safe (same model as every WPF handler in the app).
- `Detach()`: unregister + remove hook; idempotent. Only `Attach`/`Detach`/`Pressed`/
  `LastError` are public; XML-doc them.
- Needs only `WindowsBase`/`PresentationCore` (`HwndSource`) — take `IntPtr`, not
  `Window`, to avoid a PresentationFramework reference.
- Dev path: new guarded `Add-Type` block in `Start-Donut.ps1` mirroring the MVVM block
  (same by-path reference resolution), keyed on `'Donut.Interop.HotkeyManager' -as [type]`.
  Prod: the csproj globs all `.cs` — nothing to do.

**New `src/Models/HotkeyGesture.psm1`** — pure, static-parse model:
- `static [HotkeyGesture] Parse([string]$text)` ⇒ properties `Valid`, `Reason`,
  `Modifiers` (uint bitmask: Alt 0x1, Ctrl 0x2, Shift 0x4, Win 0x8), `VirtualKey`
  (uint), `Normalized` (canonical `Ctrl+Alt+D` form).
- Split on `+`, trim, case-insensitive; aliases: Ctrl/Control, Win/Windows/Super,
  Esc/Escape etc. Key token via `[System.Windows.Input.KeyConverter]` then
  `[System.Windows.Input.KeyInterop]::VirtualKeyFromKey`. Rules: exactly one non-modifier
  key; at least one of Ctrl/Alt/Win (Shift-only rejected — it types text); empty ⇒
  invalid with reason.

**Wiring:** MainPresenter's existing `Add_SourceInitialized` handler (it already has the
HWND) parses `GetGlobalHotkey()`, and on `Valid` calls `Attach`; `Pressed` ⇒
`TrayPresenter.ShowMainWindow()`. `Attach` false ⇒ toast "Hotkey <x> is unavailable
(already in use) — pick another in Settings" + log; app continues. `Detach` in the
`Closed` handler. Settings change (step 4's save path) ⇒ `Detach` + re-parse + re-`Attach`.

Tests (`tests/Unit/HotkeyGesture.Tests.ps1`): valid combos incl. aliases and case,
normalization round-trip, missing modifier, Shift-only, two non-modifier keys, unknown
token, empty/whitespace, Win-combo accepted. (HotkeyManager itself is interop — manual.)

### Step 4 — startup task (`feat: start-with-Windows via elevated scheduled task`)

**New `src/Services/StartupTaskService.psm1`** (logic module ⇒ the Pester hook will run
its tests on every edit):
- `static [string] TaskName()` ⇒ `"DONUT-$env:USERNAME"`.
- `[hashtable] BuildLaunchSpec()` — pure: from `[Environment]::ProcessPath`; leaf
  `pwsh.exe` ⇒ `Execute = <pwsh path>`, `Argument = '-Sta -ExecutionPolicy Bypass -File
  "<SourceRoot>\Start-Donut.ps1" -Tray'`; anything else ⇒ `Execute = <that exe>`,
  `Argument = '--tray'`. Quote paths (OneDrive/spaces!). Takes the process path and
  source root as parameters so tests inject both.
- `[string] ReconcileDecision([bool]$enabled, [object]$existingTask, [hashtable]$spec)`
  — pure: returns `'Register'` (enabled, missing), `'Reregister'` (enabled, action
  Execute/Argument differs — the app moved), `'NoOp'`, or `'Unregister'` (disabled,
  present).
- `[void] Apply([bool]$enabled)` — thin shell: `Get-ScheduledTask -TaskName -ErrorAction
  SilentlyContinue`, dispatch on the decision. Register uses `Register-ScheduledTask
  -Force` with `New-ScheduledTaskAction`, `New-ScheduledTaskTrigger -AtLogOn -User
  "$env:USERDOMAIN\$env:USERNAME"`, `New-ScheduledTaskPrincipal -UserId <same> -RunLevel
  Highest -LogonType Interactive`, `New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries
  -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)` (verify that zero
  disables the limit on this OS build; if the cmdlet rejects it, fall back to schtasks
  XML — but check first, the cmdlet path is preferred). Wrap in try/catch: failure logs
  + toasts ("Could not update the startup task — is DONUT running as administrator?")
  and never throws to the caller.
- Call `Apply(GetStartWithWindows())` (a) when the setting changes on config save, and
  (b) once at startup after the graph is up (heals a moved install; run it on the pool,
  not the UI thread — CIM calls can stall).

**Config UI (this step also adds the step-1/3 controls):** in
`ConfigureOptionView.xaml`, a new "Startup & tray" group styled like the existing rows:
`chkStartWithWindows`, `chkCloseToTray`, `txtGlobalHotkey`. Mirror exactly how
`ConfigPresenter` reads/persists the `throttleLimit` TextBox. On save: hotkey text must
parse (`HotkeyGesture.Parse`) or the save is rejected with the reason shown (existing
dialog/toast pattern); then re-attach the hotkey and `Apply` the task setting.

Tests (`tests/Unit/StartupTaskService.Tests.ps1`): `BuildLaunchSpec` for pwsh vs exe
hosts and quoting; the full `ReconcileDecision` matrix; `Apply` via a fake subclass
capturing which of Register/Unregister ran (pattern: `FakeInventoryService`).

### Step 5 — docs + lint filter + final sweep (`docs: tray/autostart/hotkey notes`)

- `tools/Invoke-Lint.ps1`: add `Donut\.Interop\.HotkeyManager` to the TypeNotFound
  filter regex AND its `.DESCRIPTION` list (same as `Donut.Qr.QrCode`).
- `docs/Architecture.md`: short section under design decisions — tray ownership (UI
  thread), RegisterHotKey-not-hooks rationale, scheduled-task autostart, single-instance
  handles. `README.md` Developer Guide: `-Tray` / `--tray` flag note.
- Re-run all gates + the full manual checklist below.

## 6. Manual verification checklist (end of each UI step + final)

Local (non-domain dev box — AD/SCCM errors in the log are expected and unrelated):
- [ ] `pwsh -File src\Start-Donut.ps1` — window + tray icon; Open/Exit/click behaviors;
      X honors `closeToTray` on/off; Exit runs the Lens teardown (log line) and the icon
      disappears (no ghost).
- [ ] `pwsh -File src\Start-Donut.ps1 -Tray` — no splash, no window; icon click restores;
      deferred sign-in/update prompt appears on FIRST open only.
- [ ] Hotkey: fires with the window visible, hidden-to-tray, and while another app is
      foreground; conflict case (register e.g. `Ctrl+Alt+D` in another tool first) ⇒
      toast, app fine; invalid gesture rejected at save with reason.
- [ ] Second launch while running ⇒ first instance foregrounds, second exits silently.
- [ ] Toggle Start with Windows on ⇒ task visible in Task Scheduler with Highest
      run-level and correct action; `Start-ScheduledTask DONUT-<user>` launches to tray
      elevated; toggle off ⇒ task gone. Move/rename simulation: registered task with a
      doctored action re-registers on next startup.
- [ ] `DispatcherWatchdog` logs no UI-stall warnings during any of the above.

Deferred to Danial on a domain machine: real logon-trigger fire, PsExec elevation
behavior, EDR reaction on the org image.

## 7. Acceptance criteria

- All three features work on the dev path and the prod launcher path identically.
- Zero new non-layout lint findings; format check green; full unit suite green
  (baseline 523 + new tests, 0 failures).
- No `SetWindowsHookEx` / key-state polling / raw input anywhere in the diff.
- No PS scriptblock handed to any non-dispatcher async callback.
- Exit path unchanged: tray Exit and (when `closeToTray` off) X both run the existing
  Closed teardown exactly once.

## 8. Out of scope

- Code-signing the launcher/MSI (tracked separately; would remove the Defender-exclusion
  install step and is the real fix for EDR side-eye at an unsigned autostart task).
- Gesture-capture UI (v1 is a validated TextBox).
- All-users autostart, cross-restart run recovery, minimize-to-tray-on-minimize.
