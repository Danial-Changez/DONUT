using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Management.Automation;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text.Json;
using System.Windows.Forms;

// Explicit: the tests compile this file standalone, outside the project's setting.
#nullable enable

namespace Donut.Launcher;

/// <summary>
/// First-run machine setup, run on the same elevated launch that extracts the app
/// tree. Every later launch re-checks cheaply and skips. Installs:
/// <list type="bullet">
/// <item>PsExec, which every remote operation runs through.</item>
/// <item>PowerShell 7, which worker processes need.</item>
/// </list>
/// A failure warns and defers to the next elevated launch, so an offline install
/// still opens the app and setup finishes once the network returns.
/// </summary>
public static class Bootstrap {
    // Sysinternals forbids redistribution, so PsExec is downloaded, never bundled.
    const string PsToolsUrl = "https://download.sysinternals.com/files/PSTools.zip";

    // Unpinned: pin a tag here if a bad PowerShell release ever ships.
    const string PwshReleaseApi = "https://api.github.com/repos/PowerShell/PowerShell/releases/latest";

    // An MSI still running at this point is wedged, not slow.
    const int MsiTimeoutMinutes = 10;

    // The portable zip URL carries its version, so the current one is read off the page.
    const string WizTreeDownloadPage = "https://diskanalyzer.com/download";

    /// <summary>
    /// Installs whatever prerequisite is missing, reporting progress to the splash.
    /// Three things deliberately need no install:
    /// <list type="bullet">
    /// <item>AD search and the Lens run on .NET's built-in DirectoryServices.</item>
    /// <item>Account unlock and password reset do too, which is why the RSAT
    /// ActiveDirectory module is no longer fetched: it was a Feature on Demand that
    /// cost minutes on a first run, hung indefinitely wherever Windows Update was
    /// blocked, and bought three cmdlets with LDAP equivalents.</item>
    /// <item>SCCM is reached over HTTPS, and adminServiceHost names the host when
    /// there is no local client to discover it from.</item>
    /// </list>
    /// </summary>
    /// <param name="appRoot">Extracted app tree, which is where WizTree is staged.</param>
    /// <param name="quiet">
    /// True for a tray/autostart start: setup still runs when elevated, but nothing is
    /// shown. A hidden start is de-elevated by design, and a dialog at the sign-in
    /// screen is exactly what the autostart lane must never produce.
    /// </param>
    /// <param name="warn">
    /// Raises a reason, an action and a detail. A callback rather than a dialog so this
    /// stays testable without a UI assembly graph behind it.
    /// </param>
    public static void Run(Action<int, string> report, string appRoot, bool quiet = false,
                           Action<string, string, string>? warn = null) {
        var missing = new List<(string Name, Action Install)>();
        if (FindOnPath("psexec.exe") is null) missing.Add(("PsExec", InstallPsExec));
        if (FindOnPath("pwsh.exe") is null) missing.Add(("PowerShell 7", InstallPwsh));
        // Skipped when a copy is already staged, as that one carries a supporter code.
        string wizTree = WizTreePath(appRoot);
        if (!File.Exists(wizTree)) missing.Add(("disk scan tool", () => InstallWizTree(wizTree)));
        if (missing.Count == 0) return;

        if (!IsElevated()) {
            // Same funnel as the app-tree extraction: one elevated launch finishes setup.
            if (!quiet)
                warn?.Invoke("DONUT needs one administrator launch.",
                    "Start it as administrator once to finish setup. Normal launches work after that.",
                    "Missing: " + string.Join(", ", missing.Select(m => m.Name)));
            return;
        }

        var failures = new List<string>();
        int pct = 3;
        foreach (var (name, install) in missing) {
            report(pct += 2, $"Installing {name}");
            try { install(); } catch (Exception ex) { failures.Add($"{name}: {ex.Message}"); }
        }
        if (failures.Count > 0 && !quiet)
            warn?.Invoke("Setup could not finish.",
                "It retries the next time you start DONUT as administrator.",
                string.Join("\n", failures));
    }

    /// <summary>Resolves an executable through PATH, or null when absent.</summary>
    /// <param name="searchPath">Override for tests. Defaults to the process PATH.</param>
    public static string? FindOnPath(string exeName, string? searchPath = null) {
        searchPath ??= Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (string dir in searchPath.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)) {
            // Quoted entries are legal in PATH, and File.Exists absorbs other junk.
            string candidate = Path.Combine(dir.Trim().Trim('"'), exeName);
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    /// <summary>Picks the win-x64 MSI download URL out of a GitHub release JSON document.</summary>
    public static string? SelectPwshAsset(string releaseJson) {
        using var doc = JsonDocument.Parse(releaseJson);
        foreach (var asset in doc.RootElement.GetProperty("assets").EnumerateArray()) {
            string? name = asset.GetProperty("name").GetString();
            if (name is not null &&
                name.StartsWith("PowerShell-", StringComparison.OrdinalIgnoreCase) &&
                name.EndsWith("-win-x64.msi", StringComparison.OrdinalIgnoreCase))
                return asset.GetProperty("browser_download_url").GetString();
        }
        return null;
    }

    static bool IsElevated() {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    // System32 because it is already on the PATH that bare 'psexec.exe' resolves against.
    static void InstallPsExec() {
        string tmpDir = Directory.CreateTempSubdirectory("donut-pstools").FullName;
        try {
            string zip = Path.Combine(tmpDir, "PSTools.zip");
            Download(PsToolsUrl, zip);
            string exe = Path.Combine(tmpDir, "PsExec.exe");
            using (var archive = ZipFile.OpenRead(zip))
                (archive.GetEntry("PsExec.exe")
                    ?? throw new InvalidDataException("PSTools.zip has no PsExec.exe."))
                    .ExtractToFile(exe);
            // Trust boundary: never place an unverified download into System32.
            VerifySignature(exe, "O=Microsoft Corporation");
            File.Copy(exe, Path.Combine(Environment.SystemDirectory, "psexec.exe"));
        } finally {
            try { Directory.Delete(tmpDir, true); } catch { /* best effort */ }
        }
    }

    /// <summary>Where ExecutionService.DeployWizTree looks for the scanner.</summary>
    public static string WizTreePath(string appRoot) =>
        Path.Combine(appRoot, "src", "Tools", "wiztree64.exe");

    /// <summary>Picks the portable zip URL out of the WizTree download page.</summary>
    public static string? SelectWizTreeAsset(string pageHtml) {
        var m = System.Text.RegularExpressions.Regex.Match(
            pageHtml, @"files/wiztree_\d+_\d+(?:_\d+)?_portable\.zip");
        return m.Success ? "https://diskanalyzer.com/" + m.Value : null;
    }

    // Only the scanner binary is kept, as the headless export needs no locale files.
    static void InstallWizTree(string destPath) {
        string tmpDir = Directory.CreateTempSubdirectory("donut-wiztree").FullName;
        try {
            string url = SelectWizTreeAsset(DownloadString(WizTreeDownloadPage))
                ?? throw new InvalidDataException("No portable zip link on the WizTree page.");
            string zip = Path.Combine(tmpDir, "wiztree.zip");
            Download(url, zip);
            string exe = Path.Combine(tmpDir, "WizTree64.exe");
            using (var archive = ZipFile.OpenRead(zip))
                (archive.GetEntry("WizTree64.exe")
                    ?? throw new InvalidDataException("The zip has no WizTree64.exe."))
                    .ExtractToFile(exe);
            VerifySignature(exe, "O=Antibody Software Limited");
            Directory.CreateDirectory(Path.GetDirectoryName(destPath)!);
            File.Copy(exe, destPath, true);
        } finally {
            try { Directory.Delete(tmpDir, true); } catch { /* best effort */ }
        }
    }

    // Patches this process's PATH too: the MSI's only reaches processes started later.
    static void InstallPwsh() {
        string tmpDir = Directory.CreateTempSubdirectory("donut-pwsh").FullName;
        try {
            string url = SelectPwshAsset(DownloadString(PwshReleaseApi))
                ?? throw new InvalidDataException("No win-x64 MSI in the latest PowerShell release.");
            string msi = Path.Combine(tmpDir, "PowerShell-win-x64.msi");
            Download(url, msi);
            VerifySignature(msi, "O=Microsoft Corporation");

            using var p = Process.Start(new ProcessStartInfo {
                FileName = "msiexec.exe",
                Arguments = $"/i \"{msi}\" /quiet /norestart",
                UseShellExecute = false,
            })!;
            // Bounded because Windows Installer waits its turn rather than failing.
            if (!p.WaitForExit(MsiTimeoutMinutes * 60 * 1000)) {
                try { p.Kill(entireProcessTree: true); } catch { /* already gone */ }
                throw new TimeoutException(
                    $"msiexec did not finish within {MsiTimeoutMinutes} minutes (another install " +
                    "holding the Windows Installer lock?).");
            }
            if (p.ExitCode is not (0 or 3010))   // 3010 = success, reboot pending
                throw new InvalidOperationException($"msiexec exited with {p.ExitCode}.");

            string pwshDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "PowerShell", "7");
            if (Directory.Exists(pwshDir) && FindOnPath("pwsh.exe") is null)
                Environment.SetEnvironmentVariable("PATH",
                    Environment.GetEnvironmentVariable("PATH") + Path.PathSeparator + pwshDir);
        } finally {
            try { Directory.Delete(tmpDir, true); } catch { /* best effort */ }
        }
    }

    static void Download(string url, string destPath) {
        using var http = NewHttpClient();
        using var response = http.GetAsync(url).GetAwaiter().GetResult();
        response.EnsureSuccessStatusCode();
        using var fs = File.Create(destPath);
        response.Content.CopyToAsync(fs).GetAwaiter().GetResult();
    }

    static string DownloadString(string url) {
        using var http = NewHttpClient();
        return http.GetStringAsync(url).GetAwaiter().GetResult();
    }

    static HttpClient NewHttpClient() {
        var http = new HttpClient();
        // GitHub's API rejects requests without a User-Agent.
        http.DefaultRequestHeaders.UserAgent.ParseAdd("DONUT-Setup");
        return http;
    }

    // Every download here runs elevated later, so a spoofed one has to fail here.
    static void VerifySignature(string file, string expectedSigner) {
        using var ps = PowerShell.Create();
        ps.AddCommand("Get-AuthenticodeSignature").AddParameter("FilePath", file);
        var sig = ps.Invoke<Signature>().FirstOrDefault()
            ?? throw new CryptographicException(
                $"Could not read a signature from {Path.GetFileName(file)}.");
        if (sig.Status != SignatureStatus.Valid)
            throw new CryptographicException(
                $"{Path.GetFileName(file)} failed Authenticode verification " +
                $"({sig.Status}: {sig.StatusMessage}).");
        if (sig.SignerCertificate?.Subject.Contains(
                expectedSigner, StringComparison.OrdinalIgnoreCase) != true)
            throw new CryptographicException(
                $"{Path.GetFileName(file)} is signed by an unexpected publisher " +
                $"({sig.SignerCertificate?.Subject}).");
    }
}
