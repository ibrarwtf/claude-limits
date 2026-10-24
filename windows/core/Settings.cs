using System;
using System.IO;
using System.Collections.Generic;
using System.Runtime.Serialization;

namespace ClaudeLimits
{
    /// JSON file under %APPDATA%\claude-limits\ — the UserDefaults stand-in.
    /// Locked because the token loader reads it from a background thread.
    public sealed partial class Settings
    {
        /// Fixture mode: defaults only, never read from or written to disk, so
        /// snapshots show default toggles and leave the user's settings alone.
        public static bool InMemory;
        // Lazy so InMemory can be set before the first read of settings.json.
        static readonly Lazy<Settings> shared = new Lazy<Settings>(() => new Settings());
        public static Settings Shared => shared.Value;
        readonly object gate = new object();
        readonly string path = Path.Combine(Platform.DataDir, "settings.json");
        SettingsData d;

        Settings()
        {
            try { if (!InMemory && File.Exists(path)) d = Json.Parse<SettingsData>(File.ReadAllBytes(path)); }
            catch (Exception e) { Log.Write($"settings.json unreadable, starting fresh: {e.Message}"); }
            d = d ?? new SettingsData();
        }

        // Callers hold gate.
        void Save()
        {
            if (InMemory) return;
            try { Json.WriteFileAtomic(path, Json.Write(d)); }
            catch (Exception e) { Log.Write($"settings save failed: {e.Message}"); }
        }

        /// Pill position in physical screen pixels; null = default spot by the tray.
        public (int x, int y)? PillPosition
        {
            get { lock (gate) return d.pillX.HasValue && d.pillY.HasValue ? (d.pillX.Value, d.pillY.Value) : ((int, int)?)null; }
            set { lock (gate) { d.pillX = value?.x; d.pillY = value?.y; Save(); } }
        }

        public bool LaunchAtStartup
        {
            get { if (InMemory) return false; try { return Platform.RunAtStartup; } catch { return false; } }
            set { if (InMemory) return; try { Platform.RunAtStartup = value; } catch (Exception e) { Log.Write($"autostart toggle failed: {e.Message}"); } }
        }
    }
}
