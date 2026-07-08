using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Security.Cryptography;

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

        // Splash art is embedded, so it paints immediately - no wait on disk or extraction.
        var splash = new SplashForm();
        splash.Show();
        var progress = new StartupProgress(splash);

        try
        {
            // Run PowerShell in a separate STA thread to support WPF
            Thread psThread = new Thread(() =>
            {
                try
                {
                    // Always run from the embedded copy: self-extract the app tree, then
                    // point PowerShell at the extracted Start-Donut.ps1.
                    progress.Report(3, "Unpacking resources");
                    string scriptPath = Path.Combine(ExtractEmbeddedApp(), "src", "Start-Donut.ps1");
                    if (!File.Exists(scriptPath))
                    {
                        MessageBox.Show($"Could not find Start-Donut.ps1 at:\n{scriptPath}", "Error",
                            MessageBoxButtons.OK, MessageBoxIcon.Error);
                        return;
                    }

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

    // Self-extracts the embedded app tree to a stable, world-readable dir, verified per file
    // by SHA-256 (rewriting only missing/changed/tampered ones); returns the root path.
    static string ExtractEmbeddedApp()
    {
        var asm = typeof(Program).Assembly;
        string root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "DONUT", "app");

        // Serialize concurrent launches so two instances don't write the same files.
        using var mtx = new Mutex(false, "Global\\DonutAppExtract");
        bool owned = false;
        try { owned = mtx.WaitOne(TimeSpan.FromSeconds(60)); }
        catch (AbandonedMutexException) { owned = true; }
        try
        {
            var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in asm.GetManifestResourceNames())
            {
                if (!(name.StartsWith("src/", StringComparison.Ordinal) ||
                      name.StartsWith("assets/", StringComparison.Ordinal) ||
                      name.StartsWith("res/", StringComparison.Ordinal)))
                    continue;

                string rel = name.Replace('/', Path.DirectorySeparatorChar)
                                 .Replace('\\', Path.DirectorySeparatorChar);
                string dest = Path.Combine(root, rel);
                keep.Add(Path.GetFullPath(dest));

                using Stream? s = asm.GetManifestResourceStream(name);
                if (s is null || !NeedsWrite(dest, s)) continue;

                Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                s.Position = 0;
                using var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None);
                s.CopyTo(fs);
            }
            PruneUnknown(root, keep);
            return root;
        }
        finally { if (owned) mtx.ReleaseMutex(); }
    }

    // True when the on-disk file is missing, a different size, or a different SHA-256 than
    // the embedded stream (absent, updated, or tampered). Leaves the stream at end.
    static bool NeedsWrite(string dest, Stream embedded)
    {
        if (!File.Exists(dest)) return true;
        if (embedded.CanSeek && new FileInfo(dest).Length != embedded.Length) return true;

        embedded.Position = 0;
        byte[] want = SHA256.HashData(embedded);
        using var fs = File.OpenRead(dest);
        return !want.AsSpan().SequenceEqual(SHA256.HashData(fs));
    }

    // Best-effort removal of extracted files no longer embedded (absorbs files dropped
    // across updates); never touches anything outside the app root.
    static void PruneUnknown(string root, HashSet<string> keep)
    {
        try
        {
            if (!Directory.Exists(root)) return;
            foreach (string f in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
                if (!keep.Contains(Path.GetFullPath(f)))
                    try { File.Delete(f); } catch { /* file in use */ }
        }
        catch { /* nothing to prune */ }
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
    public TrayApplicationContext()
    {
        trayIcon = new NotifyIcon()
        {
            Icon = EmbeddedAssets.LoadIcon("assets/Images/donut icon48x48.ico") ?? System.Drawing.SystemIcons.Application,
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
