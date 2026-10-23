using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;

namespace ClaudeLimits
{
    enum IconLevel { Normal, Warn, Critical, Error }

    /// Draws the notification-area icon: the 5h percentage as a number, since
    /// the tray only fits a small square — no room for the Mac's text title.
    static class TrayIcon
    {
        static Icon appIcon;

        public static Icon AppIcon(int size)
        {
            if (appIcon == null)
            {
                try { appIcon = Icon.ExtractAssociatedIcon(Platform.ExePath); } catch { }
            }
            return appIcon == null ? SystemIcons.Application : new Icon(appIcon, size, size);
        }

        public static IconLevel LevelFor(double utilization) =>
            utilization >= 95 ? IconLevel.Critical : utilization >= 80 ? IconLevel.Warn : IconLevel.Normal;

        public static Bitmap RenderBitmap(string text, IconLevel level, bool darkTaskbar, int size)
        {
            var bmp = new Bitmap(size, size, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.TextRenderingHint = TextRenderingHint.AntiAlias;
                g.Clear(Color.Transparent);

                Color fg = darkTaskbar ? Color.White : Color.FromArgb(0x1B, 0x1B, 0x1B);
                if (level != IconLevel.Normal)
                {
                    // Filled badge so a high reading is unmissable at a glance.
                    Color bg = level == IconLevel.Warn ? Color.FromArgb(0xF7, 0xA2, 0x3B)
                             : level == IconLevel.Critical ? Color.FromArgb(0xE5, 0x48, 0x4D)
                             : Color.FromArgb(0x8A, 0x8A, 0x8A);
                    using (var path = RoundedRect(new RectangleF(0, 0, size, size), size * 0.22f))
                    using (var brush = new SolidBrush(bg))
                        g.FillPath(brush, path);
                    fg = level == IconLevel.Warn ? Color.Black : Color.White;
                }

                // Glyph outlines scaled to fit, rather than DrawString: exact
                // centring at 16px, and "100" shrinks instead of clipping.
                using (var family = new FontFamily("Segoe UI"))
                using (var path = new GraphicsPath())
                {
                    path.AddString(text, family, (int)FontStyle.Bold, 100f, PointF.Empty, StringFormat.GenericTypographic);
                    var b = path.GetBounds();
                    if (b.Width > 0 && b.Height > 0)
                    {
                        float pad = level == IconLevel.Normal ? 0.5f : size * 0.12f;
                        float maxW = size - pad * 2, maxH = size * (level == IconLevel.Normal ? 0.72f : 0.58f);
                        float scale = Math.Min(maxW / b.Width, maxH / b.Height);
                        using (var m = new Matrix())
                        {
                            m.Translate(size / 2f, size / 2f);
                            m.Scale(scale, scale);
                            m.Translate(-(b.X + b.Width / 2f), -(b.Y + b.Height / 2f));
                            path.Transform(m);
                        }
                        using (var brush = new SolidBrush(fg))
                            g.FillPath(brush, path);
                    }
                }
            }
            return bmp;
        }

        public static Icon Render(string text, IconLevel level, bool darkTaskbar, int size)
        {
            using (var bmp = RenderBitmap(text, level, darkTaskbar, size))
            {
                var h = bmp.GetHicon();
                try { using (var tmp = Icon.FromHandle(h)) return (Icon)tmp.Clone(); }
                finally { Native.DestroyIcon(h); }
            }
        }

        static GraphicsPath RoundedRect(RectangleF r, float radius)
        {
            var p = new GraphicsPath();
            float d = radius * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }
    }
}
