using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Security.Cryptography;

namespace Donut.Launcher;

/// <summary>
/// Launcher entry point. Shows the startup splash on the main UI thread, then hosts the
/// DONUT PowerShell and WPF app on a dedicated STA worker thread while a bare WinForms
/// message loop keeps it alive. The process hard-exits when the app window closes, and
/// the tray icon is owned by the PowerShell side rather than here.
/// </summary>
static class Program {
    /// <summary>How long to wait for the instance we are replacing to release the mutex.</summary>
    const int AwaitPredecessorSeconds = 15;

    /// <summary>Process entry point. STA is required by WPF and WinForms.</summary>
    /// <param name="args">
    /// <c>--tray</c> starts hidden in the tray for autostart. <c>--await-pid &lt;pid&gt;</c>
    /// waits for that process to exit first, so an elevation relaunch does not lose the
    /// single-instance race.
    /// <c>--extract-only</c> writes the app tree and exits, for an elevated installer.
    /// </param>
    [STAThread]
    static void Main(string[] args) {
        // Staged by an elevated installer, so the first desktop launch need not be.
        if (args.Contains("--extract-only")) { ExtractEmbeddedApp(); return; }

        bool tray = args.Contains("--tray");

        // Before the mutex: it is per-session, so an elevated relaunch would collide.
        AwaitPredecessor(args);

        var instanceMutex = new Mutex(true, "Local\\DONUT.SingleInstance", out bool createdNew);
        if (!createdNew) {
            try {
                using var evt = EventWaitHandle.OpenExisting("Local\\DONUT.ShowRequest");
                evt.Set();
            } catch { /* first instance not fully up yet - nothing to signal */ }
            return;
        }

        ApplicationConfiguration.Initialize();

        // A tray start constructs it but never shows it (StartupProgress then no-ops).
        var splash = new SplashForm();
        if (!tray) { splash.Show(); }
        var progress = new StartupProgress(splash);

        try {
            Thread psThread = new Thread(() => {
                try {
                    // Always the embedded copy, never a checkout beside the exe.
                    progress.Report(3, "Unpacking resources");
                    string appRoot = ExtractEmbeddedApp();
                    string scriptPath = Path.Combine(appRoot, "src", "Start-Donut.ps1");
                    if (!File.Exists(scriptPath)) {
                        ErrorDialog.Show("DONUT Setup", "DONUT could not find its app files.",
                            "Reinstall DONUT, or start it as administrator once to unpack them again.",
                            scriptPath);
                        return;
                    }

                    // Quiet on a tray start: no dialogs on the logon screen.
                    Bootstrap.Run(progress.Report, appRoot, quiet: tray);

                    var iss = InitialSessionState.CreateDefault();
                    iss.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.Bypass;
                    iss.ApartmentState = ApartmentState.STA;
                    iss.ThreadOptions = PSThreadOptions.UseCurrentThread;

                    iss.Variables.Add(new SessionStateVariableEntry(
                        "Splash", progress, "DONUT startup splash reporter"));

                    // Tells the PS side to boot windowless, and that the lock is held.
                    iss.Variables.Add(new SessionStateVariableEntry(
                        "StartHidden", tray, "DONUT hidden (tray) start"));
                    iss.Variables.Add(new SessionStateVariableEntry(
                        "SingleInstanceOwned", true, "Launcher owns the single-instance mutex"));

                    using (var ps = PowerShell.Create(iss)) {
                        ps.AddScript($"& '{scriptPath}'");
                        var results = ps.Invoke();

                        if (ps.HadErrors) {
                            string errors = string.Join("\n", ps.Streams.Error.Select(e => e.ToString()));
                            ErrorDialog.Show("DONUT", "DONUT started with errors.",
                                "It may not work correctly. Open the log for the full run.", errors);
                        }
                    }
                } catch (UnauthorizedAccessException ex) {
                    ErrorDialog.Show("DONUT Setup", "DONUT needs one administrator launch.",
                        "Start it as administrator once to finish setup. Normal launches work after that.",
                        ex.ToString());
                } catch (Exception ex) {
                    ErrorDialog.Show("DONUT", "DONUT could not start.",
                        "Open the log for the full run, or start it as administrator once.",
                        ex.ToString());
                } finally {
                    // Backstop: dismiss the splash if startup threw before DonutApp closed it.
                    progress.Complete();

                    // Only for when no window showed, as a normal close exits itself.
                    Environment.Exit(0);
                }
            });

            psThread.SetApartmentState(ApartmentState.STA); // For WPF
            psThread.IsBackground = true;
            psThread.Start();

            // Bare loop because the tray icon lives on the PS and WPF side.
            Application.Run(new ApplicationContext());
            GC.KeepAlive(instanceMutex);
        } catch (Exception ex) {
            ErrorDialog.Show("DONUT", "DONUT could not start.",
                "Try again. If it keeps happening, reinstall DONUT.", ex.ToString());
        }
    }

    // Best-effort: a gone or unreadable pid means there is nothing left to wait for.
    static void AwaitPredecessor(string[] args) {
        int flag = Array.IndexOf(args, "--await-pid");
        if (flag < 0 || flag + 1 >= args.Length) return;
        if (!int.TryParse(args[flag + 1], out int pid)) return;

        try {
            using var predecessor = Process.GetProcessById(pid);
            predecessor.WaitForExit(AwaitPredecessorSeconds * 1000);
        } catch (ArgumentException) {
            // already exited
        } catch (InvalidOperationException) {
            // exited between the lookup and the wait
        }
    }

    // Beside the exe, not ProgramData: an MSI install makes that admin-only NTFS.
    static string ExtractEmbeddedApp() {
        var asm = typeof(Program).Assembly;
        string root = Path.Combine(AppContext.BaseDirectory, "app");

        // Serialize concurrent launches so two instances don't write the same files.
        using var mtx = new Mutex(false, "Global\\DonutAppExtract");
        bool owned = false;
        try { owned = mtx.WaitOne(TimeSpan.FromSeconds(60)); } catch (AbandonedMutexException) { owned = true; }
        try {
            var keep = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string name in asm.GetManifestResourceNames()) {
                if (!(name.StartsWith("src/", StringComparison.Ordinal) ||
                      name.StartsWith("assets/", StringComparison.Ordinal) ||
                      name.StartsWith("res/", StringComparison.Ordinal)))
                    continue;

                // XAML is read straight from this assembly, so it needs no file.
                if (name.StartsWith("src/", StringComparison.Ordinal) &&
                    name.EndsWith(".xaml", StringComparison.OrdinalIgnoreCase))
                    continue;

                string rel = name.Replace('/', Path.DirectorySeparatorChar)
                                 .Replace('\\', Path.DirectorySeparatorChar);
                string dest = Path.Combine(root, rel);
                keep.Add(Path.GetFullPath(dest));

                using Stream? s = asm.GetManifestResourceStream(name);
                if (s is null || !NeedsWrite(dest, s)) continue;

                // Never widened: this tree runs elevated, so a user-writable copy is an LPE.
                try {
                    Directory.CreateDirectory(Path.GetDirectoryName(dest)!);
                    s.Position = 0;
                    using var fs = new FileStream(dest, FileMode.Create, FileAccess.Write, FileShare.None);
                    s.CopyTo(fs);
                } catch (UnauthorizedAccessException ex) {
                    throw new UnauthorizedAccessException(
                        $"Could not write the app tree at {root}.\n\n" +
                        "This run is not elevated and the install folder is admin-only. " +
                        "Start DONUT as administrator once to create or update it.", ex);
                }
            }
            // Downloaded by Bootstrap rather than embedded, so Prune must spare it.
            keep.Add(Path.GetFullPath(Bootstrap.WizTreePath(root)));
            PruneUnknown(root, keep);

            // Earlier builds left a world-readable copy of this code in ProgramData.
            string legacy = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                "DONUT", "app");
            try {
                if (Directory.Exists(legacy)) Directory.Delete(legacy, true);
            } catch {
                // in use or de-elevated, so the next elevated run gets it
            }

            return root;
        } finally { if (owned) mtx.ReleaseMutex(); }
    }

    // Leaves the stream at its end.
    static bool NeedsWrite(string dest, Stream embedded) {
        if (!File.Exists(dest)) return true;
        if (embedded.CanSeek && new FileInfo(dest).Length != embedded.Length) return true;

        embedded.Position = 0;
        byte[] want = SHA256.HashData(embedded);
        using var fs = File.OpenRead(dest);
        return !want.AsSpan().SequenceEqual(SHA256.HashData(fs));
    }

    // Absorbs files dropped across updates, never reaching outside the app root.
    static void PruneUnknown(string root, HashSet<string> keep) {
        try {
            if (!Directory.Exists(root)) return;
            foreach (string f in Directory.GetFiles(root, "*", SearchOption.AllDirectories))
                if (!keep.Contains(Path.GetFullPath(f)))
                    try { File.Delete(f); } catch { /* file in use */ }
        } catch { /* nothing to prune */ }
    }
}
