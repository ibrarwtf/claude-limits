using System;
using System.IO;
using System.Reflection;
using Microsoft.Win32;

namespace ClaudeLimits
{
    /// Windows plumbing with no UI: data dir, version, autostart, URL scheme.
    /// The Mac equivalents live in Settings.swift (LaunchAgent) and Info.plist.
    public static class Platform
    {
        public const string Name = "claude-limits";

        public static readonly string DataDir = Ensure(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), Name));

        public static string ExePath => Assembly.GetEntryAssembly()?.Location
                                        ?? Path.Combine(AppDomain.CurrentDomain.BaseDirectory, Name + ".exe");

        public static string Version
        {
            get
            {
                var a = Assembly.GetEntryAssembly() ?? Assembly.GetExecutingAssembly();
                var info = a.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
                return string.IsNullOrEmpty(info) ? "0.0.0" : info;
            }
        }

        static string Ensure(string dir) { Directory.CreateDirectory(dir); return dir; }

        const string runKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        /// HKCU Run entry is the per-user, no-admin equivalent of the LaunchAgent.
        public static bool RunAtStartup
        {
            get
            {
                using (var k = Registry.CurrentUser.OpenSubKey(runKey))
                    return k?.GetValue(Name) != null;
            }
            set
            {
                using (var k = Registry.CurrentUser.CreateSubKey(runKey))
                {
                    if (value) k.SetValue(Name, $"\"{ExePath}\"");
                    else if (k.GetValue(Name) != null) k.DeleteValue(Name);
                }
            }
        }

        /// Point the Run entry at the current exe if it's enabled — keeps autostart
        /// working after the user moves the folder they unzipped into.
        public static void RefreshRunAtStartupPath()
        {
            try { if (RunAtStartup) RunAtStartup = true; } catch { }
        }

        /// Register claude-limits:// for the current user. Re-run every launch so the
        /// handler always points at the exe that's actually running.
        public static void RegisterUrlScheme()
        {
            try
            {
                using (var k = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{Name}"))
                {
                    k.SetValue("", $"URL:{Name}");
                    k.SetValue("URL Protocol", "");
                    using (var icon = k.CreateSubKey("DefaultIcon")) icon.SetValue("", $"\"{ExePath}\",0");
                    using (var cmd = k.CreateSubKey(@"shell\open\command")) cmd.SetValue("", $"\"{ExePath}\" \"%1\"");
                }
            }
            catch (Exception e) { Log.Write($"URL scheme registration failed: {e.Message}"); }
        }

        const string personalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";

        /// Taskbar / flyout theme (Settings → Personalization → "Choose your Windows mode").
        public static bool SystemUsesDarkTheme => ReadDword(personalizeKey, "SystemUsesLightTheme", 0) == 0;
        /// App-window theme ("Choose your app mode").
        public static bool AppsUseDarkTheme => ReadDword(personalizeKey, "AppsUseLightTheme", 1) == 0;

        /// Windows accent colour as 0xRRGGBB, or null.
        public static int? AccentColor
        {
            get
            {
                // AccentColorMenu is stored ABGR.
                int abgr = ReadDword(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Accent", "AccentColorMenu", -1);
                if (abgr == -1) return null;
                int r = abgr & 0xFF, g = (abgr >> 8) & 0xFF, b = (abgr >> 16) & 0xFF;
                return (r << 16) | (g << 8) | b;
            }
        }

        static int ReadDword(string key, string name, int fallback)
        {
            try
            {
                using (var k = Registry.CurrentUser.OpenSubKey(key))
                    return k?.GetValue(name) is int v ? v : fallback;
            }
            catch { return fallback; }
        }
    }
}
