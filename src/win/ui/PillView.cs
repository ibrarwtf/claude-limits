using System;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace ClaudeLimits
{
    /// What the Mac status-item button would show. Either the three parts
    /// (each null when hidden) or a single Plain string ("—", "·", an error
    /// symbol, a marquee window).
    sealed class MenuBarTitle
    {
        public string Pct, Wave, Reset;
        public string Plain;
        public bool Mono;
        /// Number for the tray icon; null → no number (icon shows Plain glyph or the app icon).
        public int? TrayNumber;
        public double Utilization;
        public bool IsError;

        public bool IsEmpty => Plain == null && Pct == null && Wave == null && Reset == null;
    }

    /// Builds the pill's visual. Shared by the live pill, the flyout header, the
    /// Settings preview and the snapshot renderer, so they can't drift apart.
    static class PillView
    {
        const string blocks = "▁▂▃▄▅▆▇█";
        const double fontSize = 12;
        const double barW = 3, barGap = 1.5, barMaxH = 12;

        static bool IsBlocks(string s) => !string.IsNullOrEmpty(s) && s.All(c => blocks.IndexOf(c) >= 0);

        public static FrameworkElement Build(MenuBarTitle t, string fgKey = "PillFg")
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            if (t.Plain != null)
            {
                if (IsBlocks(t.Plain)) row.Children.Add(Bars(t.Plain, fgKey));
                else row.Children.Add(Text(t.Plain, fgKey, t.Mono ? Theme.MonoFont : Theme.UIFont, t.Mono ? 11.5 : fontSize));
                return row;
            }
            bool prev = false;
            if (t.Pct != null)
            {
                var tb = Text(t.Pct, fgKey, Theme.UIFont, fontSize);
                // Fixed slot widths so the pill doesn't jitter as digits change —
                // the Mac clamps the status-item width for the same reason.
                tb.MinWidth = Measure("100%", Theme.UIFont, fontSize);
                tb.TextAlignment = TextAlignment.Right;
                row.Children.Add(tb);
                prev = true;
            }
            if (t.Wave != null)
            {
                var b = Bars(t.Wave, fgKey);
                if (prev) b.Margin = new Thickness(6, 0, 0, 0);
                row.Children.Add(b);
                prev = true;
            }
            if (t.Reset != null)
            {
                var tb = Text(t.Reset, fgKey, Theme.UIFont, fontSize);
                tb.MinWidth = Measure("9:59", Theme.UIFont, fontSize);
                if (prev) tb.Margin = new Thickness(6, 0, 0, 0);
                row.Children.Add(tb);
            }
            return row;
        }

        /// The pill chrome around Build(): rounded taskbar-coloured capsule.
        public static Border Capsule(MenuBarTitle t)
        {
            var border = new Border
            {
                CornerRadius = new CornerRadius(6),
                BorderThickness = new Thickness(1),
                Padding = new Thickness(9, 4, 9, 4),
                Child = Build(t),
                SnapsToDevicePixels = true,
            };
            border.SetResourceReference(Border.BackgroundProperty, "PillBg");
            border.SetResourceReference(Border.BorderBrushProperty, "PillBorder");
            return border;
        }

        static TextBlock Text(string s, string fgKey, FontFamily font, double size)
        {
            var tb = new TextBlock { Text = s, FontFamily = font, FontSize = size, VerticalAlignment = VerticalAlignment.Center };
            tb.SetResourceReference(TextBlock.ForegroundProperty, fgKey);
            return tb;
        }

        /// Sparkline drawn as rectangles rather than ▁..█ glyphs: block-element
        /// coverage and baselines vary across Windows fonts, shapes don't.
        static FrameworkElement Bars(string wave, string fgKey)
        {
            var panel = new StackPanel { Orientation = Orientation.Horizontal, Height = barMaxH, VerticalAlignment = VerticalAlignment.Center };
            foreach (var c in wave)
            {
                int level = Math.Max(0, blocks.IndexOf(c));
                var r = new Rectangle
                {
                    Width = barW,
                    Height = Math.Max(1.5, barMaxH * (level + 1) / 8.0),
                    VerticalAlignment = VerticalAlignment.Bottom,
                    Margin = new Thickness(0, 0, barGap, 0),
                    RadiusX = 0.75, RadiusY = 0.75,
                };
                r.SetResourceReference(Shape.FillProperty, fgKey);
                panel.Children.Add(r);
            }
            return panel;
        }

        public static double Measure(string s, FontFamily font, double size)
        {
            var ft = new FormattedText(s, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface(font, FontStyles.Normal, FontWeights.Normal, FontStretches.Normal), size, Brushes.Black, 1.0);
            return Math.Ceiling(ft.WidthIncludingTrailingWhitespace);
        }
    }
}
