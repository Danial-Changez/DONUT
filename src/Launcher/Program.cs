using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Security.Cryptography;

namespace Donut.Launcher;

/// <summary>
/// Launcher entry point. Shows the startup splash on the main (UI) thread, then hosts the
/// DONUT PowerShell/WPF app on a dedicated STA worker thread while a bare WinForms message
/// loop keeps it alive; the process hard-exits when the app window closes. The tray icon is
/// owned by the PowerShell/WPF side, not here.
/// </summary>
static class Program
{
    /// <summary>How long to wait for the instance we are replacing to release the mutex.</summary>
    const int AwaitPredecessorSeconds = 15;

    /// <summary>Process entry point; STA is required by WPF and WinForms.</summary>
    /// <param name="args">
    /// <c>--tray</c> starts hidden in the tray (autostart). <c>--await-pid &lt;pid&gt;</c> waits for
    /// that process to exit first, so an elevation relaunch does not lose the single-instance race.
    /// </param>
    [STAThread]
    static void Main(string[] args)
    {
        bool tray = args.Contains("--tray");

        // Before the mutex, not after: it is Local\-scoped, so per-session and not per-token.
        // An elevated relaunch would otherwise bow out as a "second instance" of its parent.
        AwaitPredecessor(args);

        // Single instance: the first launch owns the mutex; a later launch signals the
        // running instance to surface its window and exits without a second UI.
        var instanceMutex = new Mutex(true, "Local\\DONUT.SingleInstance", out bool createdNew);
        if (!createdNew)
        {
            try
            {
                using var evt = EventWaitHandle.OpenExisting("Local\\DONUT.ShowRequest");
                evt.Set();
            }
            catch { /* first instance not fully up yet - nothing to signal */ }
            return;
        }

        ApplicationConfiguration.Initialize();

        // Splash art is embedded, so it paints immediately - no wait on disk or extraction.
        // A tray start constructs it but never shows it (StartupProgress then no-ops).
        var splash = new SplashForm();
        if (!tray) { splash.Show(); }
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

                    // $StartHidden drives the tray (no-window) boot; $SingleInstanceOwned
                    // tells the PS side the launcher already holds the single-instance lock.
                    iss.Variables.Add(new SessionStateVariableEntry(
                        "StartHidden", tray, "DONUT hidden (tray) start"));
                    iss.Variables.Add(new SessionStateVariableEntry(
                        "SingleInstanceOwned", true, "Launcher owns the single-instance mutex"));

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

            // Bare message loop: the tray icon now lives on the PS/WPF side; this only
            // keeps the process (and its single-instance mutex) alive until the app exits.
            Application.Run(new ApplicationContext());
            GC.KeepAlive(instanceMutex);
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "Fatal Error");
        }
    }

    // Waits out the instance being replaced, so an elevation relaunch can take the mutex.
    // Best-effort: a gone/unreadable pid means there is nothing left to wait for.
    static void AwaitPredecessor(string[] args)
    {
        int flag = Array.IndexOf(args, "--await-pid");
        if (flag < 0 || flag + 1 >= args.Length) return;
        if (!int.TryParse(args[flag + 1], out int pid)) return;

        try
        {
            using var predecessor = Process.GetProcessById(pid);
            predecessor.WaitForExit(AwaitPredecessorSeconds * 1000);
        }
        catch (ArgumentException) { /* already exited */ }
        catch (InvalidOperationException) { /* exited between the lookup and the wait */ }
    }

    // Self-extracts the embedded app tree BESIDE the exe, verified per file by SHA-256
    // (rewriting only missing/changed/tampered ones); returns the root path. Beside the
    // exe means Program Files under an MSI install - NTFS admin-only write, the right
    // home for code (data stays in ProgramData\DONUT\data) - and a user-writable folder
    // for a portable run. The tree only changes when this exe changes (an upgrade, which
    // is elevated), so the normal refresh is elevated too; a de-elevated launch against
    // a stale tree gets the start-as-admin-once guidance below.
    static string ExtractEmbeddedApp()
    {
        var asm = typeof(Program).Assembly;
        string root = Path.Combine(AppContext.BaseDirectory, "app");

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

                // XAML never touches disk: ViewLoader/ResourceService read it from this
                // assembly (EmbeddedAssets). Only what MUST be a file is extracted - the
                // PowerShell graph (using module / worker children / the LensAgent task
                // resolve real paths), tools, fonts and images. PruneUnknown clears any
                // xaml an older build extracted.
                if (name.StartsWith("src/", StringComparison.Ordinal) &&
                    name.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase))
                    continue;

                string rel = name.Replace('/', Path.DirectorySeparatorChar)
                                 .Replace('\\', Path.DirectorySeparatorChar);
                string dest = Path.Combine(root, rel);
                keep.Add(Path.GetFullPath(dest));

                using Stream? s = asm.GetManifestResourceStream(name);
                if (s is null || !NeedsWrite(dest, s)) continue;

                // Deliberately NOT widened for de-elevated writers: this tree is what an
                // elevated DONUT executes, so local-user write access here is an LPE.
                try
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    s.Position = 0;
                    using var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None);
                    s.CopyTo(fs);
                }
                catch (UnauthorizedAccessException ex)
                {
                    throw new UnauthorizedAccessException(
                        $"Could not write the app tree at {root}.\n\n" +
                        "This run is not elevated and the install folder is admin-only. " +
                        "Start DONUT as administrator once to create or update it.", ex);
                }
            }
            PruneUnknown(root, keep);

            // One-time cleanup: earlier builds extracted to ProgramData - a world-readable
            // copy of the code this ACL-protected tree supersedes. Best-effort.
            string legacy = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "DONUT", "app");
            try { if (Directory.Exists(legacy)) Directory.Delete(legacy, true); }
            catch { /* in use or de-elevated; the next elevated run gets it */ }

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
