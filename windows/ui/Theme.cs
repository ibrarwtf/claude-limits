using System;
using System.Windows;
using System.Windows.Media;

namespace ClaudeLimits
{
    /// Light/dark brush sets. Two axes, matching Windows itself: the taskbar-side
    /// surfaces (tray icon, pill, flyout) follow the *Windows* mode; the Settings
    /// window follows the *app* mode.
    static class Theme
    {
        public static event Action Changed;

        public static bool SystemDark => Platform.SystemUsesDarkTheme;
        public static bool AppsDark => Platform.AppsUseDarkTheme;

        public static void Init()
        {
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, e) =>
            {
                if (e.Category == Microsoft.Win32.UserPreferenceCategory.General
                    || e.Category == Microsoft.Win32.UserPreferenceCategory.Color)
                    Application.Current?.Dispatcher.BeginInvoke(new Action(() => Changed?.Invoke()));
            };
        }

        static readonly Uri stylesUri = new Uri("pack://application:,,,/claude-limits;component/ui/Styles.xaml");

        public static Color Hex(int rgb, byte a = 255) =>
            Color.FromArgb(a, (byte)((rgb >> 16) & 0xFF), (byte)((rgb >> 8) & 0xFF), (byte)(rgb & 0xFF));

        static SolidColorBrush B(uint argb) { var b = new SolidColorBrush(Hex((int)(argb & 0xFFFFFF), (byte)(argb >> 24))); b.Freeze(); return b; }

        /// Brush key, dark ARGB, light ARGB. The pill sits on/near the taskbar, so
        /// it takes taskbar colours.
        static readonly (string key, uint dark, uint light)[] palette =
        {
            ("Bg", 0xFF202020, 0xFFF3F3F3), ("Surface", 0xFF2C2C2C, 0xFFF9F9F9), ("Fg", 0xFFFFFFFF, 0xFF1B1B1B),
            ("FgDim", 0x9EFFFFFF, 0x9E000000), ("FgFaint", 0x66FFFFFF, 0x6B000000), ("Divider", 0x1AFFFFFF, 0x14000000),
            ("ControlBg", 0x0FFFFFFF, 0xB3FFFFFF), ("ControlBorder", 0x1FFFFFFF, 0x24000000), ("HoverOverlay", 0x10FFFFFF, 0x0A000000),
            ("InputBg", 0xFF1C1C1C, 0xFFFFFFFF), ("SwitchOffBg", 0x30000000, 0x06000000), ("SwitchOffBorder", 0x9EFFFFFF, 0x9E000000),
            ("SwitchOffThumb", 0xC8FFFFFF, 0x9E000000), ("Link", 0xFF99EBFF, 0xFF005FB8), ("BarEmpty", 0x24FFFFFF, 0x1A000000),
            ("Coral", 0xFFFFAA88, 0xFFD97755), ("CoralFill", 0x4DFFAA88, 0x59FF9966), ("Orange", 0xFFF7A23B, 0xFFF7A23B),
            ("Green", 0xFF3FB950, 0xFF3FB950), ("Red", 0xFFE5484D, 0xFFE5484D),
            ("PillBg", 0xF21C1C1C, 0xF2EEEEEE), ("PillFg", 0xFFFFFFFF, 0xFF1B1B1B), ("PillBorder", 0x1FFFFFFF, 0x1A000000),
        };

        public static Color AccentColor(bool dark)
        {
            // AccentColorMenu is tuned for light surfaces; the dark-mode accent
            // Windows itself uses is lighter, so lift it toward white.
            var c = Hex(Clock.IsPinned ? 0x0078D4 : Platform.AccentColor ?? 0x0078D4);
            if (!dark) return c;
            return Color.FromRgb((byte)(c.R + (255 - c.R) * 0.35), (byte)(c.G + (255 - c.G) * 0.35), (byte)(c.B + (255 - c.B) * 0.35));
        }

        public static ResourceDictionary Make(bool dark)
        {
            var d = new ResourceDictionary();
            d.MergedDictionaries.Add(new ResourceDictionary { Source = stylesUri });
            var accent = new SolidColorBrush(AccentColor(dark)); accent.Freeze();
            d["Accent"] = accent;
            // Pick the accent foreground for contrast against the accent itself.
            var ac = AccentColor(dark);
            bool accentIsLight = (0.299 * ac.R + 0.587 * ac.G + 0.114 * ac.B) > 150;
            d["AccentFg"] = accentIsLight ? B(0xFF000000) : B(0xFFFFFFFF);
            foreach (var (key, dk, lt) in palette) d[key] = B(dark ? dk : lt);
            return d;
        }

        public static void Apply(FrameworkElement root, bool dark)
        {
            root.Resources = Make(dark);
            TextElementDefaults(root);
        }

        static void TextElementDefaults(FrameworkElement root)
        {
            root.SetValue(TextOptions.TextFormattingModeProperty, TextFormattingMode.Display);
            System.Windows.Documents.TextElement.SetFontFamily(root, UIFont);
            System.Windows.Documents.TextElement.SetFontSize(root, 12.0);
            root.SetResourceReference(System.Windows.Documents.TextElement.ForegroundProperty, "Fg");
        }

        // Fixture renders stick to fonts every Windows image has (CI runners are
        // Windows Server, without the Win11 variable font or Cascadia).
        static readonly FontFamily uiFont = new FontFamily("Segoe UI Variable Text, Segoe UI");
        static readonly FontFamily uiFontFixed = new FontFamily("Segoe UI");
        static readonly FontFamily monoFont = new FontFamily("Cascadia Mono, Consolas");
        static readonly FontFamily monoFontFixed = new FontFamily("Consolas");
        public static FontFamily UIFont => Clock.IsPinned ? uiFontFixed : uiFont;
        public static FontFamily MonoFont => Clock.IsPinned ? monoFontFixed : monoFont;
    }
}
