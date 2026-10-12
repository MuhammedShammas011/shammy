// InputInjector.cs
// MacLink – Windows Host
// Injects mouse and keyboard events using Windows SendInput API.
// Accessibility note: SendInput cannot inject into elevated processes (UAC dialogs,
// Task Manager, etc.) unless the host is also running elevated.

using System;
using System.Runtime.InteropServices;
using MacLink.Windows.Protocol;

namespace MacLink.Windows.Input
{
    public class InputInjector
    {
        // ─── SendInput P/Invoke ───────────────────────────────────────────────────

        [DllImport("user32.dll", SetLastError = true)]
        static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

        [DllImport("user32.dll")]
        static extern bool GetCursorPos(out POINT lpPoint);

        [DllImport("user32.dll")]
        static extern int GetSystemMetrics(int index);

        const int SM_CXSCREEN = 0;
        const int SM_CYSCREEN = 1;

        [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

        [StructLayout(LayoutKind.Sequential)]
        struct MOUSEINPUT
        {
            public int  dx, dy;
            public uint mouseData, dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT
        {
            public ushort wVk, wScan;
            public uint   dwFlags, time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Explicit)]
        struct INPUT_UNION
        {
            [FieldOffset(0)] public MOUSEINPUT  mi;
            [FieldOffset(0)] public KEYBDINPUT  ki;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct INPUT
        {
            public uint       type;
            public INPUT_UNION u;
        }

        const uint INPUT_MOUSE    = 0;
        const uint INPUT_KEYBOARD = 1;
        const uint MOUSEEVENTF_MOVE        = 0x0001;
        const uint MOUSEEVENTF_LEFTDOWN    = 0x0002;
        const uint MOUSEEVENTF_LEFTUP      = 0x0004;
        const uint MOUSEEVENTF_RIGHTDOWN   = 0x0008;
        const uint MOUSEEVENTF_RIGHTUP     = 0x0010;
        const uint MOUSEEVENTF_MIDDLEDOWN  = 0x0020;
        const uint MOUSEEVENTF_MIDDLEUP    = 0x0040;
        const uint MOUSEEVENTF_WHEEL       = 0x0800;
        const uint MOUSEEVENTF_HWHEEL      = 0x1000;
        const uint MOUSEEVENTF_ABSOLUTE    = 0x8000;
        const uint KEYEVENTF_KEYUP         = 0x0002;
        const uint KEYEVENTF_UNICODE       = 0x0004;

        // ─── State ───────────────────────────────────────────────────────────────

        private int _screenW => GetSystemMetrics(SM_CXSCREEN);
        private int _screenH => GetSystemMetrics(SM_CYSCREEN);
        private bool _leftDown, _rightDown;

        // ─── Mouse ───────────────────────────────────────────────────────────────

        public void InjectMouseMove(double normX, double normY, int displayWidth, int displayHeight)
        {
            // Convert normalized [0,1] coords to absolute SendInput coords [0,65535]
            int ax = (int)(normX * 65535);
            int ay = (int)(normY * 65535);

            var input = new INPUT
            {
                type = INPUT_MOUSE,
                u    = new INPUT_UNION
                {
                    mi = new MOUSEINPUT
                    {
                        dx       = ax,
                        dy       = ay,
                        dwFlags  = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
                    }
                }
            };
            SendInput(1, [input], Marshal.SizeOf<INPUT>());
        }

        public void InjectMouseButton(MouseButtonPayload payload, int displayWidth, int displayHeight)
        {
            // Move to click position first
            if (payload.NormX >= 0 && payload.NormY >= 0)
                InjectMouseMove(payload.NormX, payload.NormY, displayWidth, displayHeight);

            uint flags = payload.Button switch
            {
                "left"   => payload.Pressed ? MOUSEEVENTF_LEFTDOWN   : MOUSEEVENTF_LEFTUP,
                "right"  => payload.Pressed ? MOUSEEVENTF_RIGHTDOWN  : MOUSEEVENTF_RIGHTUP,
                "middle" => payload.Pressed ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP,
                _        => 0
            };
            if (flags == 0) return;

            if (payload.Button == "left")  _leftDown  = payload.Pressed;
            if (payload.Button == "right") _rightDown = payload.Pressed;

            var input = new INPUT
            {
                type = INPUT_MOUSE,
                u    = new INPUT_UNION { mi = new MOUSEINPUT { dwFlags = flags } }
            };
            SendInput(1, [input], Marshal.SizeOf<INPUT>());

            // Double-click: send second down+up pair
            if (payload.ClickCount == 2 && payload.Pressed)
            {
                uint flags2 = payload.Button switch
                {
                    "left"  => MOUSEEVENTF_LEFTUP,
                    "right" => MOUSEEVENTF_RIGHTUP,
                    _       => 0
                };
                var up2   = new INPUT { type = INPUT_MOUSE, u = new INPUT_UNION { mi = new MOUSEINPUT { dwFlags = flags2 } } };
                var down2 = new INPUT { type = INPUT_MOUSE, u = new INPUT_UNION { mi = new MOUSEINPUT { dwFlags = flags } } };
                SendInput(1, [up2, down2], Marshal.SizeOf<INPUT>());
            }
        }

        public void InjectScroll(MouseScrollPayload payload)
        {
            // Vertical scroll
            if (Math.Abs(payload.DeltaY) > 0.01)
            {
                int wheel = (int)(-payload.DeltaY * 120); // WHEEL_DELTA = 120
                var input = new INPUT
                {
                    type = INPUT_MOUSE,
                    u    = new INPUT_UNION
                    {
                        mi = new MOUSEINPUT
                        {
                            mouseData = (uint)wheel,
                            dwFlags   = MOUSEEVENTF_WHEEL
                        }
                    }
                };
                SendInput(1, [input], Marshal.SizeOf<INPUT>());
            }

            // Horizontal scroll
            if (Math.Abs(payload.DeltaX) > 0.01)
            {
                int hwheel = (int)(payload.DeltaX * 120);
                var input = new INPUT
                {
                    type = INPUT_MOUSE,
                    u    = new INPUT_UNION
                    {
                        mi = new MOUSEINPUT
                        {
                            mouseData = (uint)hwheel,
                            dwFlags   = MOUSEEVENTF_HWHEEL
                        }
                    }
                };
                SendInput(1, [input], Marshal.SizeOf<INPUT>());
            }
        }

        // ─── Keyboard ────────────────────────────────────────────────────────────

        public void InjectKey(KeyEventPayload payload)
        {
            ushort winVK = KeyCodeMap.ToWindows(payload.KeyCode);
            if (winVK == 0)
            {
                // If we have character hint, use Unicode injection instead
                if (!string.IsNullOrEmpty(payload.Characters))
                {
                    if (payload.Pressed) InjectText(payload.Characters);
                    return;
                }
                return;
            }

            // Apply modifiers
            PushModifiers(payload.Modifiers, down: true);

            var input = new INPUT
            {
                type = INPUT_KEYBOARD,
                u    = new INPUT_UNION
                {
                    ki = new KEYBDINPUT
                    {
                        wVk     = winVK,
                        dwFlags = payload.Pressed ? 0u : KEYEVENTF_KEYUP
                    }
                }
            };
            SendInput(1, [input], Marshal.SizeOf<INPUT>());

            if (!payload.Pressed)
                PushModifiers(payload.Modifiers, down: false);
        }

        public void InjectText(string text)
        {
            foreach (char c in text)
            {
                var down = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u    = new INPUT_UNION
                    {
                        ki = new KEYBDINPUT
                        {
                            wScan   = c,
                            dwFlags = KEYEVENTF_UNICODE
                        }
                    }
                };
                var up = new INPUT
                {
                    type = INPUT_KEYBOARD,
                    u    = new INPUT_UNION
                    {
                        ki = new KEYBDINPUT
                        {
                            wScan   = c,
                            dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
                        }
                    }
                };
                SendInput(1, [down], Marshal.SizeOf<INPUT>());
                SendInput(1, [up],   Marshal.SizeOf<INPUT>());
            }
        }

        private void PushModifiers(uint macMods, bool down)
        {
            const uint flagDown = 0u;

            // macOS ⌘ Command → Windows Ctrl (closest semantic equivalent for shortcuts)
            if ((macMods & KeyCodeMap.MacCommand) != 0)
                PushVK(0x11 /* VK_CONTROL */, down);

            if ((macMods & KeyCodeMap.MacControl) != 0)
                PushVK(0x11 /* VK_CONTROL */, down);

            if ((macMods & KeyCodeMap.MacShift) != 0)
                PushVK(0x10 /* VK_SHIFT */, down);

            if ((macMods & KeyCodeMap.MacOption) != 0)
                PushVK(0x12 /* VK_MENU/Alt */, down);
        }

        private void PushVK(ushort vk, bool down)
        {
            var input = new INPUT
            {
                type = INPUT_KEYBOARD,
                u    = new INPUT_UNION
                {
                    ki = new KEYBDINPUT
                    {
                        wVk     = vk,
                        dwFlags = down ? 0u : KEYEVENTF_KEYUP
                    }
                }
            };
            SendInput(1, [input], Marshal.SizeOf<INPUT>());
        }
    }
}
