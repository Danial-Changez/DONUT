using System;
using System.Windows.Forms;

namespace Donut.Launcher;

/// <summary>
/// Progress reporter handed to the PowerShell session as <c>$Splash</c>. DONUT's
/// startup script (DonutApp.ps1) calls <see cref="Report"/> at each init milestone
/// and <see cref="Complete"/> when the app is ready (or on failure). Both are invoked
/// from the PowerShell worker thread and marshal onto the splash's UI thread.
/// </summary>
public sealed class StartupProgress
{
    private readonly SplashForm _splash;

    public StartupProgress(SplashForm splash) => _splash = splash;

    /// <summary>Reports an init milestone, moving the splash bar to a determinate value.</summary>
    /// <param name="percent">Completion for this milestone, 0–100.</param>
    /// <param name="status">Short status line shown under the bar (e.g. "Loading resources").</param>
    /// <remarks>Called from the PowerShell worker thread; the update is posted to the UI thread.</remarks>
    public void Report(int percent, string status) =>
        Post(() => _splash.SetProgress(percent, status));

    /// <summary>Fills the bar and dismisses the splash once the app is ready (or on failure).</summary>
    /// <remarks>
    /// Idempotent — safe to call again from <see cref="Program"/>'s finally block as a backstop.
    /// </remarks>
    public void Complete() => Post(_splash.CompleteAndClose);

    // Marshals a splash update onto its UI thread, tolerating an already-closed splash.
    private void Post(Action action)
    {
        // Handle is created the moment the splash is shown on the main thread, well
        // before the first report; if it isn't (or the splash is gone), drop the call.
        if (_splash.IsDisposed || !_splash.IsHandleCreated) return;
        try
        {
            _splash.BeginInvoke(action);
        }
        catch (ObjectDisposedException) { /* splash already closed */ }
        catch (InvalidOperationException) { /* handle race during teardown */ }
    }
}
