// The dev path compiles this standalone via Add-Type, where the csproj's setting
// does not apply, so the nullable context rides in the file itself.
#nullable enable
using System;
using System.IO;
using Microsoft.Win32;
using System.Net.NetworkInformation;

namespace Donut.Interop {
    // Drops the lens warm flag on resume or network change, so the agent re-warms at
    // once. Pure .NET: these events fire on threads that hold no PowerShell runspace.
    public static class LensWarmTriggers {
        private static string? _flagPath;
        private static DateTime _lastPoke = DateTime.MinValue;
        private static PowerModeChangedEventHandler? _powerHandler;
        private static NetworkAddressChangedEventHandler? _netHandler;

        // Register and Unregister run on the UI thread only, so they need no locking.
        public static void Register(string flagPath) {
            if (_powerHandler != null) return;
            _flagPath = flagPath;
            _powerHandler = (s, e) => { if (e.Mode == PowerModes.Resume) Poke(); };
            _netHandler = (s, e) => Poke();
            SystemEvents.PowerModeChanged += _powerHandler;
            NetworkChange.NetworkAddressChanged += _netHandler;
        }

        public static void Unregister() {
            if (_powerHandler == null) return;
            SystemEvents.PowerModeChanged -= _powerHandler;
            NetworkChange.NetworkAddressChanged -= _netHandler;
            _powerHandler = null;
            _netHandler = null;
        }

        // VPN bursts are rate limited, and a lost race only writes the same flag twice.
        public static void Poke() {
            var path = _flagPath;
            if (path == null) return;
            var now = DateTime.UtcNow;
            if (now - _lastPoke < TimeSpan.FromSeconds(30)) return;
            _lastPoke = now;
            try {
                // A missing dir means no agent (de-elevated, or torn down): nothing to poke.
                var dir = Path.GetDirectoryName(path);
                if (dir == null || !Directory.Exists(dir)) return;
                File.WriteAllText(path, now.ToString("o"));
            } catch {
                // Best effort: the 4-minute ping still covers a failed poke.
            }
        }
    }
}
