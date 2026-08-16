#nullable enable
using System;
using System.Runtime.InteropServices;
using System.Windows.Interop;

namespace Donut.Interop {
    /// <summary>
    /// Constrains a borderless (WindowChrome) window's maximized bounds to the monitor
    /// work area, so maximizing does not overflow the screen edges or cover the taskbar.
    /// WPF's WindowChrome does not do this for WindowStyle=None windows.
    /// </summary>
    public static class WindowChromeHelper {
        private const int WM_GETMINMAXINFO = 0x0024;
        private const int MONITOR_DEFAULTTONEAREST = 0x00000002;

        /// <summary>Hooks the window's WndProc. Call once after the HWND exists.</summary>
        public static void ConstrainMaximize(IntPtr hwnd) {
            HwndSource? source = HwndSource.FromHwnd(hwnd);
            if (source != null) { source.AddHook(WndHook); }
        }

        private static IntPtr WndHook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled) {
            if (msg == WM_GETMINMAXINFO) { AdjustMaxInfo(hwnd, lParam); }
            return IntPtr.Zero;
        }

        // Rewrites the maximized position/size to the work area of the window's monitor.
        private static void AdjustMaxInfo(IntPtr hwnd, IntPtr lParam) {
            MINMAXINFO mmi = Marshal.PtrToStructure<MINMAXINFO>(lParam);
            IntPtr monitor = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
            if (monitor != IntPtr.Zero) {
                MONITORINFO info = new MONITORINFO { cbSize = Marshal.SizeOf<MONITORINFO>() };
                GetMonitorInfo(monitor, ref info);
                RECT work = info.rcWork;
                RECT mon = info.rcMonitor;
                mmi.ptMaxPosition.X = Math.Abs(work.Left - mon.Left);
                mmi.ptMaxPosition.Y = Math.Abs(work.Top - mon.Top);
                mmi.ptMaxSize.X = Math.Abs(work.Right - work.Left);
                mmi.ptMaxSize.Y = Math.Abs(work.Bottom - work.Top);
            }
            Marshal.StructureToPtr(mmi, lParam, true);
        }

        [DllImport("user32.dll")]
        private static extern IntPtr MonitorFromWindow(IntPtr handle, int flags);

        [DllImport("user32.dll")]
        private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFO lpmi);

        [StructLayout(LayoutKind.Sequential)]
        private struct POINT { public int X; public int Y; }

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct MINMAXINFO {
            public POINT ptReserved;
            public POINT ptMaxSize;
            public POINT ptMaxPosition;
            public POINT ptMinTrackSize;
            public POINT ptMaxTrackSize;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MONITORINFO {
            public int cbSize;
            public RECT rcMonitor;
            public RECT rcWork;
            public int dwFlags;
        }
    }
}
