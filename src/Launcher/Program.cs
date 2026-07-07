using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace Donut.Launcher;

static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();

        // Path to the PowerShell entry point
        string exePath = AppDomain.CurrentDomain.BaseDirectory;

        // 1. Try relative to executable (Production/Release)
        // Expected: bin/x64/DONUT/Donut.Launcher.exe -> ../../../src/Scripts/Start-Donut.ps1
        string scriptPath = Path.GetFullPath(Path.Combine(exePath, "..", "..", "..", "src", "Start-Donut.ps1"));

        // 2. Try relative to source (Debug/Dev)
        // Expected: src/Launcher/bin/Debug/net9.0-windows/Donut.Launcher.exe -> ../../../../Scripts/Start-Donut.ps1
        if (!File.Exists(scriptPath))
        {
            scriptPath = Path.GetFullPath(Path.Combine(exePath, "..", "..", "..", "..", "Start-Donut.ps1"));
        }

        if (!File.Exists(scriptPath))
        {
            MessageBox.Show($"Could not find Start-Donut.ps1 at:\n{scriptPath}", "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }

        // The splash reads its art from <repo>/assets/Images, derived from the resolved
        // script path so it works in both the dev and installed layouts.
        string? assetsDir = null;
        try
        {
            string? srcDir = Path.GetDirectoryName(scriptPath);            // ...\src
            string? repoRoot = srcDir is null ? null : Path.GetDirectoryName(srcDir);
            if (repoRoot is not null)
                assetsDir = Path.Combine(repoRoot, "assets", "Images");
        }
        catch { /* splash falls back to its install-path candidate */ }

        // Show the splash immediately on the main (UI) thread, before the app graph
        // parses on the worker thread — so it animates while the parse blocks.
        var splash = new SplashForm(assetsDir);
        splash.Show();
        var progress = new StartupProgress(splash);

        // Captured on the UI thread (the WinForms sync context is installed once the splash
        // creates its handle) so the worker thread can end the tray loop when the app closes.
        var uiContext = System.Threading.SynchronizationContext.Current;

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
                    // Backstop: dismiss the splash even if startup threw before
                    // DonutApp.ps1 could close it.
                    progress.Complete();

                    // The WPF app has shut down (main window closed, and any background
                    // teardown awaited in DonutApp.ps1 has finished). End the tray message
                    // loop so the launcher process exits instead of lingering as a background
                    // process — which otherwise keeps the exe locked against rebuilds.
                    if (uiContext is not null)
                        uiContext.Post(_ => Application.Exit(), null);
                    else
                        Application.Exit();
                }
            });

            psThread.SetApartmentState(ApartmentState.STA); // For WPF
            psThread.IsBackground = true;
            psThread.Start();

            // Hosts the message loop (and the tray icon) while the WPF app runs on the worker
            // thread; ends when that thread signals Application.Exit above.
            using (var tray = new TrayApplicationContext())
            {
                Application.Run(tray);
            }
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Fatal Error");
        }
    }
}

public class TrayApplicationContext : ApplicationContext
{
    private NotifyIcon trayIcon;
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
    }

    void Exit(object? sender, EventArgs e)
    {
        // Dispose the icon if it was created from file
        try
        {
            trayIcon.Icon?.Dispose();
        }
        catch { }

        trayIcon.Visible = false;
        Application.Exit();
        Environment.Exit(0);
    }

    // Runs when the message loop ends (worker thread signalled Application.Exit) so the
    // tray icon is removed instead of lingering as a ghost until the mouse hovers it.
    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            try
            {
                trayIcon.Visible = false;
                trayIcon.Icon?.Dispose();
                trayIcon.Dispose();
            }
            catch { }
        }
        base.Dispose(disposing);
    }
}
