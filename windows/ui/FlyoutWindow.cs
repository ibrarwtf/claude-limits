using System;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;

using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    /// The dropdown's rows, built from app state. Shared by the live flyout and
    /// the snapshot renderer (the Mac builds one NSMenuItem array for both too).
    sealed class FlyoutView
    {
        public const double RowWidth = 360;
        const double leftPad = 10, rightPad = 10;

        public readonly FrameworkElement Root;
        readonly TrayApp app;
        readonly Action<Action> invoke;
        TextBlock statusText, resetText;

        public FlyoutView(TrayApp app, Action<Action> invoke)
        {
            this.app = app;
            this.invoke = invoke;
            Root = Build();
        }

        /// Called once a second while open so "Last updated: Xs ago" visibly ticks.
        public void Tick()
        {
            statusText.Text = app.FormatTopStatusLine();
            var f = app.LastResponse?.FiveHour;
            if (resetText != null && f != null) resetText.Text = app.FormatResetLine(f);
        }

        FrameworkElement Build()
        {
            var s = new StackPanel { Width = RowWidth, Margin = new Thickness(0, 6, 0, 6) };

            // The tray icon only fits a number, so the full menu-bar line leads
            // the flyout (always all three parts, regardless of pill toggles).
            var hero = PillView.Build(app.DataTitle(respectToggles: false), "Fg");
            hero.LayoutTransform = new ScaleTransform(1.35, 1.35);
            hero.HorizontalAlignment = HorizontalAlignment.Left;
            s.Children.Add(new Border { Padding = new Thickness(leftPad, 6, rightPad, 6), Child = hero });

            foreach (var row in MenuRows(app.LastError, app.LastResponse)) s.Children.Add(RowView(row));
            return s;
        }

        /// Rows come from menu_rows in logic/core.pl; this only draws them.
        FrameworkElement RowView(Row row)
        {
            switch (row.Kind)
            {
                case RowKind.Status: return TextRow(app.FormatTopStatusLine(), "FgDim", out statusText);
                case RowKind.Reset: return TextRow(app.FormatResetLine(app.LastResponse.FiveHour), "FgDim", out resetText);
                case RowKind.Separator: return Separator();
                case RowKind.Header: return TextRow(row.Text, "FgDim", out _);
                case RowKind.Bar: return TabularRow(row.Label, row.Utilization, row.Value);
                case RowKind.Pair: return PairRow(row.Label, row.Value);
                default:
                    var a = row.Does;
                    return ActionRow(row.Label, a == MenuAction.Refresh ? app.RefreshAction : a == MenuAction.OpenUsage ? app.OpenUsageWeb
                                              : a == MenuAction.Quit ? (Action)app.Quit : app.OpenSettings);
            }
        }

        static TextBlock Label(string text, string fgKey)
        {
            var tb = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap };
            tb.SetResourceReference(TextBlock.ForegroundProperty, fgKey);
            return tb;
        }

        static FrameworkElement TextRow(string text, string fgKey, out TextBlock tb)
        {
            tb = Label(text, fgKey);
            return new Border { MinHeight = 22, Padding = new Thickness(leftPad, 3, rightPad, 3), Child = tb };
        }

        static FrameworkElement Separator()
        {
            var b = new Border { Height = 1, Margin = new Thickness(leftPad, 5, rightPad, 5) };
            b.SetResourceReference(Border.BackgroundProperty, "Divider");
            return b;
        }

        static FrameworkElement PairRow(string label, string value)
        {
            var g = new DockPanel { Height = 22, Margin = new Thickness(leftPad, 0, rightPad, 0), LastChildFill = true };
            var v = Label(value, "FgDim");
            DockPanel.SetDock(v, Dock.Right);
            g.Children.Add(v);
            g.Children.Add(Label(label, "FgDim"));
            return g;
        }

        /// Label, 24-block bar (filled_blocks in logic/core.pl), value flush-right —
        /// the macOS TabularRowView layout.
        public static FrameworkElement TabularRow(string label, double utilization, string value)
        {
            var g = new Grid { Height = 24, Margin = new Thickness(leftPad, 0, rightPad, 0) };
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(98) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            g.Children.Add(Label(label, "FgDim"));

            const int blockCount = 24;
            int filled = FilledBlocks(utilization, blockCount);
            var bar = new UniformGrid { Rows = 1, Columns = blockCount, Height = 10, VerticalAlignment = VerticalAlignment.Center };
            for (int i = 0; i < blockCount; i++)
            {
                var rect = new Rectangle { RadiusX = 1.5, RadiusY = 1.5, Margin = new Thickness(0, 0, 1, 0) };
                rect.SetResourceReference(Shape.FillProperty, i < filled ? "Accent" : "BarEmpty");
                bar.Children.Add(rect);
            }
            Grid.SetColumn(bar, 1);
            g.Children.Add(bar);

            var v = Label(value, "FgDim");
            v.Margin = new Thickness(6, 0, 0, 0);
            v.MinWidth = 34;
            v.TextAlignment = TextAlignment.Right;
            Grid.SetColumn(v, 2);
            g.Children.Add(v);
            return g;
        }

        FrameworkElement ActionRow(string text, Action action)
        {
            var tb = Label(text, "Fg");
            var b = new Border
            {
                Height = 26,
                Padding = new Thickness(leftPad - 4, 0, rightPad - 4, 0),
                Margin = new Thickness(4, 0, 4, 0),
                CornerRadius = new CornerRadius(4),
                Background = Brushes.Transparent,
                Child = tb,
            };
            b.MouseEnter += (_, __) => b.SetResourceReference(Border.BackgroundProperty, "HoverOverlay");
            b.MouseLeave += (_, __) => b.Background = Brushes.Transparent;
            b.MouseLeftButtonUp += (_, __) => invoke(action);
            return b;
        }
    }

    /// Borderless popup anchored to the tray icon or the pill — the NSMenu
    /// dropdown. Closes when it loses focus, like a menu.
    sealed class FlyoutWindow : Window
    {
        const double shadowMargin = 12;
        readonly FlyoutView view;
        readonly DispatcherTimer tick;

        public FlyoutWindow(TrayApp app)
        {
            Title = "claude-limits";
            WindowStyle = WindowStyle.None;
            AllowsTransparency = true;
            Background = Brushes.Transparent;
            Topmost = true;
            ShowInTaskbar = false;
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;

            // Close first, then act — same ordering as MenuRowView.mouseUp's
            // cancelTracking + deferred sendAction.
            view = new FlyoutView(app, action =>
            {
                Close();
                Dispatcher.BeginInvoke(action);
            });
            Content = Chrome(view.Root, Theme.SystemDark);

            SourceInitialized += (_, __) => Native.MakeToolWindow(new WindowInteropHelper(this).Handle, false);
            Deactivated += (_, __) => { if (IsVisible) Close(); };
            KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };

            // Not tied to the poll timer, so the counter keeps moving while open.
            tick = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            tick.Tick += (_, __) => view.Tick();
            Closed += (_, __) => tick.Stop();
        }

        /// The flyout panel: rounded surface with a soft shadow. Also used by the
        /// snapshot renderer.
        public static FrameworkElement Chrome(FrameworkElement content, bool dark)
        {
            var root = new Grid();
            Theme.Apply(root, dark);
            var panel = new Border
            {
                Margin = new Thickness(shadowMargin),
                CornerRadius = new CornerRadius(8),
                BorderThickness = new Thickness(1),
                Child = content,
                Effect = new DropShadowEffect
                {
                    BlurRadius = 18, ShadowDepth = 3, Direction = 270,
                    Opacity = dark ? 0.5 : 0.18, Color = Colors.Black,
                },
            };
            panel.SetResourceReference(Border.BackgroundProperty, "Surface");
            panel.SetResourceReference(Border.BorderBrushProperty, "Divider");
            root.Children.Add(panel);
            return root;
        }

        /// anchor: the pill's rect, or a zero-size rect at the cursor for tray clicks.
        public void ShowAt(Native.RECT anchor, bool fromPill)
        {
            Opacity = 0;
            Show();
            Activate();
            var hwnd = new WindowInteropHelper(this).Handle;
            Native.SetForegroundWindow(hwnd);
            Native.GetWindowRect(hwnd, out var r);
            int w = r.Width, h = r.Height;
            double scale = PresentationSource.FromVisual(this)?.CompositionTarget?.TransformToDevice.M11 ?? 1.0;
            int m = (int)(shadowMargin * scale);
            var center = new Native.POINT { X = (anchor.Left + anchor.Right) / 2, Y = (anchor.Top + anchor.Bottom) / 2 };
            var work = Native.WorkAreaAt(center);
            int gap = (int)(6 * scale);

            int x, y;
            if (fromPill)
            {
                x = anchor.Right - w + m;
                y = anchor.Top - h + m - gap;
                if (y + m < work.Top) y = anchor.Bottom - m + gap;
            }
            else
            {
                x = center.X - w / 2;
                if (center.Y >= work.Bottom) y = work.Bottom - h + m - gap;       // taskbar at bottom
                else if (center.Y <= work.Top) y = work.Top - m + gap;            // taskbar at top
                else y = center.Y - h + m;
            }
            x = Math.Max(work.Left - m + gap, Math.Min(x, work.Right - w + m - gap));
            y = Math.Max(work.Top - m, Math.Min(y, work.Bottom - h + m));
            Native.SetWindowPos(hwnd, Native.HWND_TOPMOST, x, y, 0, 0, Native.SWP_NOSIZE);
            Opacity = 1;
            tick.Start();
        }
    }
}
