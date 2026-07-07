using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace Donut.Launcher;

/// <summary>
/// Launcher entry point. Shows the startup splash on the main (UI) thread, then hosts the
/// DONUT PowerShell/WPF app on a dedicated STA worker thread while a tray icon keeps the
/// message loop alive; the process hard-exits when the app window closes.
/// </summary>
static class Program
{
    /// <summary>Process entry point; STA is required by WPF and WinForms.</summary>
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();

        string exePath = AppDomain.CurrentDomain.BaseDirectory;

        // Production layout: exe under bin/x64/DONUT -> ../../../src/Start-Donut.ps1.
        string scriptPath = Path.GetFullPath(Path.Combine(exePath, "..", "..", "..", "src", "Start-Donut.ps1"));

        // Dev layout: exe under src/Launcher/bin/Debug/net10.0-windows.
        if (!File.Exists(scriptPath))
        {
            scriptPath = Path.GetFullPath(Path.Combine(exePath, "..", "..", "..", "..", "Start-Donut.ps1"));
        }

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show($"Could not find Start-Donut.ps1 at:\n{scriptPath}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        // Splash art dir, derived from the script path so it resolves in dev + installed layouts.
        string? assetsDir = null;
        try
        {
            string? srcDir = Path.GetDirectoryName(scriptPath);            // ...\src
            string? repoRoot = srcDir is null ? null : Path.GetDirectoryName(srcDir);
            if (repoRoot is not null)
                assetsDir = Path.Combine(repoRoot, "assets", "Images");
        }
        catch { /* splash falls back to its install-path candidate */ }

        // Show on the main thread before the worker parses the app graph (which blocks it).
        var splash = new SplashForm(assetsDir);
        splash.Show();
        var progress = new StartupProgress(splash);

        try
        {
            // Run PowerShell in a separate STA thread to support WPF
            Thread psThread = new Thread(() =>
            {
                try
                {
                    var iss = InitialSessionState.CreateDefault();
                    iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                    iss.ApartmentState = ApartmentState.STA;
                    iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

                    // Exposed to DonutApp.ps1 as $Splash for milestone reporting.
                    iss.Variables.Add(new SessionStateVariableEntry(
                        "Splash", progress, "DONUT startup splash reporter"));

                    using (var ps = PowerShell.Create(iss))
                    {
                        // Pass the script path to ensure it runs in the correct context
                        ps.AddScript($"& '{scriptPath}'");
                        var results = ps.Invoke();

                        if (ps.HadErrors)
                        {
                            string errors = string.Join("\n", ps.Streams.Error.Select(e => e.ToString()));
                            MessageBox.Show(errors, "PowerShell Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
                        }
                    }
                }
                catch (Exception ex)
                {
                    MessageBox.Show(ex.ToString(), "Thread Error");
                }
                finally
                {
                    // Backstop: dismiss the splash if startup threw before DonutApp closed it.
                    progress.Complete();

                    // Fallback hard-exit when the main window never showed (normal close exits
                    // via the window's Closed handler); else the tray loop keeps the exe alive.
                    Environment.Exit(0);
                }
            });

            psThread.SetApartmentState(ApartmentState.STA); // For WPF
            psThread.IsBackground = true;
            psThread.Start();

            Application.Run(new TrayApplicationContext());
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Fatal Error");
        }
    }
}

/// <summary>
/// Hosts the WinForms message loop and the DONUT system-tray icon while the WPF app runs on
/// the worker thread. The "Exit" menu item hard-terminates the process.
/// </summary>
public class TrayApplicationContext : ApplicationContext
{
    private NotifyIcon trayIcon;
    private bool cleaned;
    private string iconPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Bakery", "DONUT", "assets", "Images", "logo yellow arrow.png");
    public TrayApplicationContext()
    {
        trayIcon = new NotifyIcon()
        {
            Icon = System.IO.File.Exists(iconPath) ? new System.Drawing.Icon(iconPath) : System.Drawing.SystemIcons.Application,
            Text = "DONUT",
            ContextMenuStrip = new ContextMenuStrip(),
            Visible = true
        };

        trayIcon.ContextMenuStrip.Items.Add("Exit", null, Exit);

        // The window-close and startup-backstop paths hard-exit via Environment.Exit, which
        // skips Dispose; hook ProcessExit so the icon is removed instead of ghosting until hover.
        AppDomain.CurrentDomain.ProcessExit += (_, _) => CleanupTray();
    }

    // Idempotent: ProcessExit can fire after the Exit menu already cleaned up.
    void CleanupTray()
    {
        if (cleaned) { return; }
        cleaned = true;
        try
        {
            trayIcon.Visible = false;
            trayIcon.Icon?.Dispose();
            trayIcon.Dispose();
        }
        catch { /* already disposed */ }
    }

    void Exit(object? sender, EventArgs e)
    {
        CleanupTray();
        Application.Exit();
        Environment.Exit(0);
    }
}
