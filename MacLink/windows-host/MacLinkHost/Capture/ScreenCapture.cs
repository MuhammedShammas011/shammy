// ScreenCapture.cs
// MacLink – Windows Host
// Screen capture using Windows.Graphics.Capture API (Windows 10 1803+).
// Publishes BGRA frames via event for encoding and streaming.
//
// Required NuGet: none (built-in WinRT APIs via net8.0-windows10.0.17763.0)

using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;

// Windows Runtime interop
using Windows.Graphics;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.DirectX.Direct3D11;

// D3D11 interop via SharpDX or raw COM – we use the lightweight P/Invoke approach
// with the Windows.Win32.Foundation structures. For simplicity we use GDI+ fallback
// path (BitBlt) which is universally compatible without extra NuGet packages.

namespace MacLink.Windows.Capture
{
    /// <summary>
    /// Screen frame event args — BGRA pixel data and dimensions.
    /// </summary>
    public class FrameEventArgs : EventArgs
    {
        public int Width  { get; init; }
        public int Height { get; init; }
        public byte[] Bgra { get; init; } = [];
    }

    /// <summary>
    /// Captures the primary screen using GDI BitBlt at a configurable FPS.
    /// Works on all Windows versions (no Windows.Graphics.Capture permission needed).
    ///
    /// Windows.Graphics.Capture requires a UI context to show the capture border;
    /// for a personal-use tray app, GDI capture is simpler and more compatible.
    /// To upgrade to WGC, swap this class body and inject WGC frame pool frames instead.
    /// </summary>
    public class ScreenCapture : IDisposable
    {
        public event EventHandler<FrameEventArgs>? FrameReady;

        public int TargetFPS    { get; set; } = 30;
        public int StreamWidth  { get; set; } = 1280;
        public int StreamHeight { get; set; } = 800;
        public bool IsCapturing { get; private set; }

        private CancellationTokenSource? _cts;
        private Task? _captureTask;

        // P/Invoke for GDI BitBlt
        [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
        [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
        [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
        [DllImport("gdi32.dll")]  static extern IntPtr CreateCompatibleDC(IntPtr hdc);
        [DllImport("gdi32.dll")]  static extern IntPtr CreateCompatibleBitmap(IntPtr hdc, int w, int h);
        [DllImport("gdi32.dll")]  static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
        [DllImport("gdi32.dll")]  static extern bool DeleteObject(IntPtr h);
        [DllImport("gdi32.dll")]  static extern bool DeleteDC(IntPtr hdc);
        [DllImport("gdi32.dll")]  static extern bool BitBlt(IntPtr hdcDest, int x, int y, int w, int h, IntPtr hdcSrc, int srcX, int srcY, uint rop);
        [DllImport("gdi32.dll")]  static extern int GetDIBits(IntPtr hdc, IntPtr hBm, uint start, uint lines, byte[]? bits, ref BITMAPINFO bmi, uint usage);
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("user32.dll")] static extern int GetSystemMetrics(int nIndex);
        const uint SRCCOPY = 0x00CC0020;
        const uint DIB_RGB_COLORS = 0;

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public uint  biSize, biWidth; public int biHeight;
            public ushort biPlanes, biBitCount; public uint biCompression, biSizeImage;
            public int biXPelsPerMeter, biYPelsPerMeter; public uint biClrUsed, biClrImportant;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; public uint bmiColors; }
        [StructLayout(LayoutKind.Sequential)]
        struct RECT { public int Left, Top, Right, Bottom; }

        const int SM_CXSCREEN = 0;
        const int SM_CYSCREEN = 1;

        public int ScreenWidth  => GetSystemMetrics(SM_CXSCREEN);
        public int ScreenHeight => GetSystemMetrics(SM_CYSCREEN);

        public void Start()
        {
            if (IsCapturing) return;
            IsCapturing = true;
            _cts = new CancellationTokenSource();
            _captureTask = Task.Run(() => CaptureLoop(_cts.Token));
        }

        public void Stop()
        {
            IsCapturing = false;
            _cts?.Cancel();
            _captureTask?.Wait(TimeSpan.FromSeconds(2));
        }

        private void CaptureLoop(CancellationToken ct)
        {
            int targetFps = Math.Clamp(TargetFPS, 1, 60);
            int frameMs   = 1000 / targetFps;

            while (!ct.IsCancellationRequested)
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    CaptureFrame();
                }
                catch (Exception ex)
                {
                    Console.Error.WriteLine($"[Capture] Error: {ex.Message}");
                }
                sw.Stop();
                int sleep = frameMs - (int)sw.ElapsedMilliseconds;
                if (sleep > 0) Thread.Sleep(sleep);
            }
        }

        private void CaptureFrame()
        {
            int sw = ScreenWidth;
            int sh = ScreenHeight;

            IntPtr hDesktop = GetDesktopWindow();
            IntPtr hdc      = GetDC(hDesktop);
            IntPtr hdcMem   = CreateCompatibleDC(hdc);
            IntPtr hbm      = CreateCompatibleBitmap(hdc, sw, sh);
            IntPtr hOld     = SelectObject(hdcMem, hbm);

            BitBlt(hdcMem, 0, 0, sw, sh, hdc, 0, 0, SRCCOPY);

            var bmi = new BITMAPINFO();
            bmi.bmiHeader.biSize     = (uint)Marshal.SizeOf<BITMAPINFOHEADER>();
            bmi.bmiHeader.biWidth    = (uint)sw;
            bmi.bmiHeader.biHeight   = -sh; // top-down
            bmi.bmiHeader.biPlanes   = 1;
            bmi.bmiHeader.biBitCount = 32;
            bmi.bmiHeader.biCompression = 0; // BI_RGB

            var pixels = new byte[sw * sh * 4];
            GetDIBits(hdc, hbm, 0, (uint)sh, pixels, ref bmi, DIB_RGB_COLORS);

            SelectObject(hdcMem, hOld);
            DeleteObject(hbm);
            DeleteDC(hdcMem);
            ReleaseDC(hDesktop, hdc);

            FrameReady?.Invoke(this, new FrameEventArgs
            {
                Width  = sw,
                Height = sh,
                Bgra   = pixels
            });
        }

        public void Dispose() => Stop();
    }
}
