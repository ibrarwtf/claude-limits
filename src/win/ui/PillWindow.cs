using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ClaudeLimits
{
    /// Floating always-on-top capsule showing the Mac menu-bar line
    /// ("18% ▆▇█ 4:32"). Left-click refreshes, right-click opens the flyout,
    /// drag to move — same click semantics as the Mac status item.
    sealed class PillWindow : Window
    {
        readonly TrayApp app;
        readonly Grid root = new Grid();
        readonly DispatcherTimer zTimer;
        IntPtr hwnd;
        Point? downAt;
        bool dragged;
        bool positioned;
        MenuBarTitle last = new MenuBarTitle { Plain = "—" };

        public PillWindow(TrayApp app)
        {
            this.app = app;
            Title = "claude-limits";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ShowActivated = false;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
            Content = root;
            Theme.Apply(root, Theme.SystemDark);
            Theme.Changed += () => { Theme.Apply(root, Theme.SystemDark); Render(last); };

            SourceInitialized += (_, __) =>
            {
                hwnd = new WindowInteropHelper(this).Handle;
                // Tool window: no taskbar button, no Alt-Tab entry; no-activate so
                // clicking it never steals focus from what you're typing in.
                Native.MakeToolWindow(hwnd, true);
            };
            ContentRendered += (_, __) => { if (!positioned) { positioned = true; PlaceInitially(); } };
            SizeChanged += (_, e) =>
            {
                // Keep the right edge anchored (the pill lives left of the tray),
                // so width changes grow leftward instead of sliding under the clock.
                if (positioned && e.WidthChanged && e.PreviousSize.Width > 0)
                    Left += e.PreviousSize.Width - e.NewSize.Width;
            };

            MouseLeftButtonDown += (_, e) => { downAt = e.GetPosition(this); dragged = false; CaptureMouse(); };
            MouseMove += OnMouseMove;
            MouseLeftButtonUp += (_, e) =>
            {
                ReleaseMouseCapture();
                if (downAt != null && !dragged) app.PrimaryClick();
                downAt = null;
            };
            MouseRightButtonUp += (_, e) => app.ToggleFlyout(ScreenRect(), fromPill: true);

            // The taskbar is itself topmost and re-raises when clicked; re-assert
            // our z-order once a second. Also hide while a fullscreen app runs.
            zTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            zTimer.Tick += (_, __) =>
            {
                if (hwnd == IntPtr.Zero) return;
                bool fullscreen = Native.FullscreenAppActive();
                if (fullscreen && Visibility == Visibility.Visible) Visibility = Visibility.Hidden;
                else if (!fullscreen && Visibility != Visibility.Visible) Visibility = Visibility.Visible;
                if (!fullscreen)
                    Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, 0, 0, 0, 0,
                        Native.SWP_NOMOVE | Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
            };
        }

        public void ShowPill()
        {
            Show();
            zTimer.Start();
        }

        public void HidePill()
        {
            zTimer.Stop();
            Hide();
        }

        public void Render(MenuBarTitle t)
        {
            last = t;
            root.Children.Clear();
            root.Children.Add(PillView.Capsule(t));
        }

        public Native.RECT ScreenRect()
        {
            Native.GetWindowRect(hwnd, out var r);
            return r;
        }

        void OnMouseMove(object sender, MouseEventArgs e)
        {
            if (downAt == null || e.LeftButton != MouseButtonState.Pressed) return;
            var p = e.GetPosition(this);
            if (Math.Abs(p.X - downAt.Value.X) < 4 && Math.Abs(p.Y - downAt.Value.Y) < 4) return;
            dragged = true;
            ReleaseMouseCapture();
            DragMove(); // modal until the button is released
            downAt = null;
            var r = ScreenRect();
            Settings.Shared.PillPosition = (r.Left, r.Top);
        }

        void PlaceInitially()
        {
            var r = ScreenRect();
            int w = r.Width, h = r.Height;
            var pos = Settings.Shared.PillPosition;
            if (pos.HasValue)
            {
                var saved = pos.Value;
                // Only trust a saved spot if it's still on a connected monitor.
                var mon = Native.MonitorAt(new Native.POINT { X = saved.x + w / 2, Y = saved.y + h / 2 });
                if (saved.x + w / 2 >= mon.Left && saved.x + w / 2 < mon.Right && saved.y + h / 2 >= mon.Top && saved.y + h / 2 < mon.Bottom)
                {
                    Move(saved.x, saved.y);
                    return;
                }
            }
            var (dx, dy) = DefaultPosition(w, h);
            Move(dx, dy);
        }

        /// Over the taskbar, just left of the notification area — where the Mac
        /// menu-bar text would sit. Falls back to the work area's corner when the
        /// taskbar is docked on a side or can't be found.
        static (int, int) DefaultPosition(int w, int h)
        {
            var taskbar = Native.FindWindow("Shell_TrayWnd", null);
            if (taskbar != IntPtr.Zero && Native.GetWindowRect(taskbar, out var tb) && tb.Width > tb.Height)
            {
                var mon = Native.MonitorAt(new Native.POINT { X = tb.Left + tb.Width / 2, Y = tb.Top + tb.Height / 2 });
                bool bottom = tb.Top > mon.Top + mon.Height / 2;
                if (bottom && tb.Height >= h)
                {
                    int right = tb.Right - 340;
                    var tray = Native.FindWindowEx(taskbar, IntPtr.Zero, "TrayNotifyWnd", null);
                    if (tray != IntPtr.Zero && Native.GetWindowRect(tray, out var tr) && tr.Width > 0) right = tr.Left;
                    return (right - w - 8, tb.Top + (tb.Height - h) / 2);
                }
            }
            var work = Native.WorkAreaAt(new Native.POINT { X = 0, Y = 0 });
            return (work.Right - w - 12, work.Bottom - h - 12);
        }

        void Move(int x, int y) =>
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE | Native.SWP_NOACTIVATE);
    }
}
