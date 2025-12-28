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
}
