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

        static SolidColorBrush B(int rgb, byte a = 255) { var b = new SolidColorBrush(Hex(rgb, a)); b.Freeze(); return b; }

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
            d["AccentFg"] = accentIsLight ? B(0x000000) : B(0xFFFFFF);
            if (dark)
            {
                d["Bg"] = B(0x202020);
                d["Surface"] = B(0x2C2C2C);
                d["Fg"] = B(0xFFFFFF);
                d["FgDim"] = B(0xFFFFFF, 0x9E);
                d["FgFaint"] = B(0xFFFFFF, 0x66);
                d["Divider"] = B(0xFFFFFF, 0x1A);
                d["ControlBg"] = B(0xFFFFFF, 0x0F);
                d["ControlBorder"] = B(0xFFFFFF, 0x1F);
                d["HoverOverlay"] = B(0xFFFFFF, 0x10);
                d["InputBg"] = B(0x1C1C1C);
                d["SwitchOffBg"] = B(0x000000, 0x30);
                d["SwitchOffBorder"] = B(0xFFFFFF, 0x9E);
                d["SwitchOffThumb"] = B(0xFFFFFF, 0xC8);
                d["Link"] = B(0x99EBFF);
                d["BarEmpty"] = B(0xFFFFFF, 0x24);
                d["Coral"] = B(0xFFAA88);
                d["CoralFill"] = B(0xFFAA88, 0x4D);
            }
            else
            {
                d["Bg"] = B(0xF3F3F3);
                d["Surface"] = B(0xF9F9F9);
                d["Fg"] = B(0x1B1B1B);
                d["FgDim"] = B(0x000000, 0x9E);
                d["FgFaint"] = B(0x000000, 0x6B);
                d["Divider"] = B(0x000000, 0x14);
                d["ControlBg"] = B(0xFFFFFF, 0xB3);
                d["ControlBorder"] = B(0x000000, 0x24);
                d["HoverOverlay"] = B(0x000000, 0x0A);
                d["InputBg"] = B(0xFFFFFF);
                d["SwitchOffBg"] = B(0x000000, 0x06);
                d["SwitchOffBorder"] = B(0x000000, 0x9E);
                d["SwitchOffThumb"] = B(0x000000, 0x9E);
                d["Link"] = B(0x005FB8);
                d["BarEmpty"] = B(0x000000, 0x1A);
                d["Coral"] = B(0xD97755);
                d["CoralFill"] = B(0xFF9966, 0x59);
            }
            d["Orange"] = B(0xF7A23B);
            d["Green"] = B(0x3FB950);
            d["Red"] = B(0xE5484D);
            // The pill sits on/near the taskbar, so it takes taskbar colours.
            d["PillBg"] = dark ? B(0x1C1C1C, 0xF2) : B(0xEEEEEE, 0xF2);
            d["PillFg"] = dark ? B(0xFFFFFF) : B(0x1B1B1B);
            d["PillBorder"] = dark ? B(0xFFFFFF, 0x1F) : B(0x000000, 0x1A);
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
