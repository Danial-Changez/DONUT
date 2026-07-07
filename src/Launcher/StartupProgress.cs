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

    // Called from the worker thread at each startup milestone.
    public void Report(int percent, string status) =>
        Post(() => _splash.SetProgress(percent, status));

    // Called from the worker thread once the app is ready (idempotent — safe to call
    // again from Program's finally as a backstop).
    public void Complete() => Post(_splash.CompleteAndClose);

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
