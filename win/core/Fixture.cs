using System;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;

namespace ClaudeLimits
{
    /// The app's notion of "now". Normally the wall clock; pinned in fixture mode
    /// so countdowns, "Xs ago" and the reset clock render identically every run.
    public static class Clock
    {
        public static DateTime? Pinned { get; set; }
        public static bool IsPinned => Pinned.HasValue;
        public static DateTime Now => Pinned ?? DateTime.UtcNow;
    }

    [DataContract]
    public sealed class FixtureHistoryPoint
    {
        /// Seconds before the fixture's `now`.
        [DataMember(Name = "ago")] public double Ago { get; set; }
        [DataMember(Name = "u")] public double U { get; set; }
    }

    /// spec/fixtures/*.json — a canned API response plus usage history.
    [DataContract]
    public sealed class Fixture
    {
        [DataMember(Name = "now")] public string Now { get; set; }
        [DataMember(Name = "response")] public UsageResponse Response { get; set; }
        [DataMember(Name = "history")] public FixtureHistoryPoint[] History { get; set; }
    }

    /// `--fixture <file>` loads a Fixture instead of polling Anthropic and keeps
    /// settings/history off disk; `--snapshot-all <dir>` then renders every view
    /// to PNG and exits. Mirrors mac/core/Fixture.swift.
    public static class FixtureMode
    {
        public static Fixture Fixture { get; private set; }
        public static string SnapshotDest { get; private set; }
        public static bool IsActive => Fixture != null;

        /// Must run before anything touches Settings.Shared or UsageHistory.Shared.
        public static void Configure(string[] args)
        {
            string ValueAfter(string flag)
            {
                int i = Array.IndexOf(args, flag);
                return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
            }
            var path = ValueAfter("--fixture");
            if (path == null) return;
            var fx = Json.Parse<Fixture>(File.ReadAllBytes(Token.ExpandPath(path)));
            var now = Format.ParseISO(fx.Now) ?? throw new Exception($"fixture `now` isn't ISO 8601: {fx.Now}");
            Clock.Pinned = now;
            UsageHistory.Persist = false;
            Settings.InMemory = true;
            Fixture = fx;
            var dest = ValueAfter("--snapshot-all");
            SnapshotDest = dest == null ? null : Path.GetFullPath(Token.ExpandPath(dest));
            UsageHistory.Shared.ReplaceSamples((fx.History ?? new FixtureHistoryPoint[0]).Select(h =>
                new HistorySample { TimestampUnix = Format.ToUnix(now.AddSeconds(-h.Ago)), Utilization = h.U }));
        }
    }
}
