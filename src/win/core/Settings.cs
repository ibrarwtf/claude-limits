using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;
using System.Runtime.Serialization;

namespace ClaudeLimits
{
    public enum TokenSource { Auto = 0, File = 1, Shell = 2 }

    [DataContract]
    sealed class SettingsData
    {
        [DataMember] public int tokenSourceMode;
        [DataMember] public string customFilePath;
        [DataMember] public string customShellCommand;
        [DataMember(EmitDefaultValue = false)] public double? lastSuccessfulPoll;
        [DataMember(EmitDefaultValue = false)] public double? nextAllowedPoll;
        [DataMember(EmitDefaultValue = false)] public string lastResponseJSON;
        [DataMember] public int consecutiveRateLimits;
        [DataMember] public int[] notifiedThresholds;
        [DataMember(EmitDefaultValue = false)] public string lastNotifiedResetsAt;
        [DataMember] public bool hidePercentage;
        [DataMember] public bool hideWave;
        [DataMember] public bool hideResetTime;
        [DataMember] public bool hidePill;
        [DataMember(EmitDefaultValue = false)] public int? pillX;
        [DataMember(EmitDefaultValue = false)] public int? pillY;
        [DataMember] public bool didFirstLaunch;
    }

    /// JSON file under %APPDATA%\claude-limits\ — the UserDefaults stand-in.
    /// Locked because the token loader reads it from a background thread.
    public sealed class Settings
    {
        public static readonly Settings Shared = new Settings();
        readonly object gate = new object();
        readonly string path = Path.Combine(Platform.DataDir, "settings.json");
        SettingsData d;

        Settings()
        {
            try { if (File.Exists(path)) d = Json.Parse<SettingsData>(File.ReadAllBytes(path)); }
            catch (Exception e) { Log.Write($"settings.json unreadable, starting fresh: {e.Message}"); }
            d = d ?? new SettingsData();
        }

        T Get<T>(Func<SettingsData, T> f) { lock (gate) return f(d); }
        void Set(Action<SettingsData> f)
        {
            lock (gate)
            {
                f(d);
                try { Json.WriteFileAtomic(path, Json.Write(d)); }
                catch (Exception e) { Log.Write($"settings save failed: {e.Message}"); }
            }
        }

        static DateTime? Date(double? unix) => unix.HasValue ? Format.FromUnix(unix.Value) : (DateTime?)null;
        static double? Unix(DateTime? utc) => utc.HasValue ? Format.ToUnix(utc.Value) : (double?)null;

        public TokenSource TokenSource
        {
            get => Get(x => Enum.IsDefined(typeof(TokenSource), x.tokenSourceMode) ? (TokenSource)x.tokenSourceMode : TokenSource.Auto);
            set => Set(x => x.tokenSourceMode = (int)value);
        }
        public string CustomFilePath
        {
            get => Get(x => x.customFilePath ?? "");
            set => Set(x => x.customFilePath = value);
        }
        public string CustomShellCommand
        {
            get => Get(x => x.customShellCommand ?? "");
            set => Set(x => x.customShellCommand = value);
        }
        /// Persisted across app restarts — prevents rapid relaunches from bursting the rate limit.
        public DateTime? LastSuccessfulPoll
        {
            get => Get(x => Date(x.lastSuccessfulPoll));
            set => Set(x => x.lastSuccessfulPoll = Unix(value));
        }
        /// Persisted "do not poll until" — honours Anthropic's Retry-After across launches.
        public DateTime? NextAllowedPoll
        {
            get => Get(x => Date(x.nextAllowedPoll));
            set => Set(x => x.nextAllowedPoll = Unix(value));
        }
        /// JSON-encoded last successful UsageResponse so the tray shows real data
        /// immediately on launch instead of "—".
        public string LastResponseJSON
        {
            get => Get(x => x.lastResponseJSON);
            set => Set(x => x.lastResponseJSON = value);
        }
        /// Count of consecutive rate-limit responses. Persisted across launches so
        /// install.ps1 churn doesn't reset the exponential back-off counter.
        public int ConsecutiveRateLimits
        {
            get => Get(x => x.consecutiveRateLimits);
            set => Set(x => x.consecutiveRateLimits = value);
        }
        /// Thresholds (e.g. 80, 95) already notified in the current 5h window.
        /// Reset when `LastNotifiedResetsAt` no longer matches the live `resets_at`.
        public HashSet<int> NotifiedThresholds
        {
            get => Get(x => new HashSet<int>(x.notifiedThresholds ?? new int[0]));
            set => Set(x => x.notifiedThresholds = value.ToArray());
        }
        /// `resets_at` string the threshold set was recorded against. When this
        /// changes the live window has rolled over and the set should clear.
        public string LastNotifiedResetsAt
        {
            get => Get(x => x.lastNotifiedResetsAt);
            set => Set(x => x.lastNotifiedResetsAt = value);
        }

        // Sub-toggles — stored as inverse "hide" flags so the unset/false default
        // reads as "show everything" (matches new-install expectations).
        public bool ShowPercentage { get => Get(x => !x.hidePercentage); set => Set(x => x.hidePercentage = !value); }
        public bool ShowWave       { get => Get(x => !x.hideWave);       set => Set(x => x.hideWave = !value); }
        public bool ShowResetTime  { get => Get(x => !x.hideResetTime);  set => Set(x => x.hideResetTime = !value); }
        /// Floating pill near the tray — the Windows stand-in for the menu-bar text.
        public bool ShowPill       { get => Get(x => !x.hidePill);       set => Set(x => x.hidePill = !value); }

        /// Pill position in physical screen pixels; null = default spot by the tray.
        public (int x, int y)? PillPosition
        {
            get => Get(x => x.pillX.HasValue && x.pillY.HasValue ? (x.pillX.Value, x.pillY.Value) : ((int, int)?)null);
            set => Set(x => { x.pillX = value?.x; x.pillY = value?.y; });
        }

        /// Gates the auto-open-Settings logic so it fires once for new installs only.
        public bool DidFirstLaunch
        {
            get => Get(x => x.didFirstLaunch);
            set => Set(x => x.didFirstLaunch = value);
        }

        public bool LaunchAtStartup
        {
            get { try { return Platform.RunAtStartup; } catch { return false; } }
            set { try { Platform.RunAtStartup = value; } catch (Exception e) { Log.Write($"autostart toggle failed: {e.Message}"); } }
        }
    }
}
