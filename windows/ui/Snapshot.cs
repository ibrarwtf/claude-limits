using System;
using System.IO;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Forms = System.Windows.Forms;

using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    /// All snapshot capture lives here. Triggered by `--fixture … --snapshot-all`
    /// (windows/scripts/snapshot.ps1, CI) or, for the live app,
    /// claude-limits://snapshot/<menubar|dropdown|settings>?dest=<dir>. We
    /// rebuild each view offscreen with a forced theme and RenderTargetBitmap
    /// it, so both light and dark come out regardless of the current Windows
    /// mode, without screen capture.
    static class Snapshot
    {
        const double scale = 2.0; // @2x, like the Mac PNGs

        public static void Handle(TrayApp app, Uri url) =>
            Render(app, url.AbsolutePath.Trim('/'), System.Web.HttpUtility.ParseQueryString(url.Query)["dest"] ?? Path.Combine(Platform.DataDir, "snapshots"));

        /// Every kind, light + dark — used by `--fixture … --snapshot-all <dir>`.
        public static void RenderAll(TrayApp app, string dest)
        {
            foreach (var kind in new[] { "menubar", "dropdown", "settings" }) Render(app, kind, dest);
        }

        static void Render(TrayApp app, string kind, string dest)
        {
            try
            {
                Directory.CreateDirectory(dest);
                foreach (var dark in new[] { false, true })
                {
                    FrameworkElement el;
                    switch (kind)
                    {
                        case "menubar": el = Menubar(app, dark); break;
                        case "dropdown": el = FlyoutWindow.Chrome(new FlyoutView(app, _ => { }).Root, dark); break;
                        case "settings": el = SettingsPanel(app, dark); break;
                        default: return;
                    }
                    Save(el, Path.Combine(dest, $"{kind}-{(dark ? "dark" : "light")}.png"));
                }
            }
            catch (Exception e) { Log.Write($"snapshot {kind} failed: {e}"); }
        }

        /// A strip of taskbar with the pill and the tray icon on it.
        static FrameworkElement Menubar(TrayApp app, bool dark)
        {
            var root = new Grid();
            Theme.Apply(root, dark);
            var bar = new Border { Background = new SolidColorBrush(dark ? Color.FromRgb(0x1C, 0x1C, 0x1C) : Color.FromRgb(0xEE, 0xEE, 0xEE)), Padding = new Thickness(10, 8, 12, 8) };
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(PillView.Capsule(app.CurrentTitle));
            var t = app.CurrentTitle;
            string text = TrayText(t.TrayNumber, t.IsError, t.Plain);
            if (text != null)
            {
                var level = (IconLevel)TrayLevel(t.TrayNumber, t.Utilization, t.IsError);
                using (var bmp = TrayIcon.RenderBitmap(text, level, dark, (int)(16 * scale)))
                {
                    var ms = new MemoryStream();
                    bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
                    ms.Position = 0;
                    var img = new BitmapImage();
                    img.BeginInit(); img.StreamSource = ms; img.CacheOption = BitmapCacheOption.OnLoad; img.EndInit();
                    row.Children.Add(new Image { Source = img, Width = 16, Height = 16, Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center });
                }
            }
            var clock = new TextBlock { Text = Format.ClockTime(Clock.Now), Margin = new Thickness(14, 0, 0, 0), VerticalAlignment = VerticalAlignment.Center, Foreground = dark ? Brushes.White : Brushes.Black };
            row.Children.Add(clock);
            bar.Child = row;
            root.Children.Add(bar);
            return root;
        }

        static FrameworkElement SettingsPanel(TrayApp app, bool dark)
        {
            var view = new SettingsView(app, null, null);
            Theme.Apply(view.Root, dark);
            view.Root.SetResourceReference(Panel.BackgroundProperty, "Bg");
            return view.Root;
        }

        static void Save(FrameworkElement el, string path)
        {
            el.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var size = el.DesiredSize;
            el.Arrange(new Rect(size));
            el.UpdateLayout();
            var rtb = new RenderTargetBitmap((int)Math.Ceiling(size.Width * scale), (int)Math.Ceiling(size.Height * scale),
                96 * scale, 96 * scale, PixelFormats.Pbgra32);
            rtb.Render(el);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            var tmp = path + ".tmp";
            using (var fs = File.Create(tmp)) enc.Save(fs);
            if (File.Exists(path)) File.Delete(path);
            File.Move(tmp, path);
        }
    }
}
