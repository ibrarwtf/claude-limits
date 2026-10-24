using System;
using System.IO;
using System.Linq;
using System.Collections.Generic;

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

    // Fixture / FixturePoint are generated from logic/core.pl (Logic.cs).

    /// `--fixture <file>` loads a Fixture instead of polling Anthropic and keeps
    /// settings/history off disk; `--snapshot-all <dir>` then renders every view
    /// to PNG and exits. Mirrors macos/core/Fixture.swift.
    public static class FixtureMode
    {
        public static Fixture Fixture { get; private set; }
        public static string SnapshotDest { get; private set; }
        public static bool IsActive => Fixture != null;

        /// Must run before anything touches Settings.Shared or UsageHistory.Shared.
        public static void Configure(string[] args)
        {
            var path = Logic.FlagValue(args, "--fixture");
            if (path == null) return;
            var fx = Json.Parse<Fixture>(File.ReadAllBytes(Token.ExpandPath(path)));
            var now = Format.ParseISO(fx.Now) ?? throw new Exception($"fixture `now` isn't ISO 8601: {fx.Now}");
            Clock.Pinned = now;
            UsageHistory.Persist = false;
            Settings.InMemory = true;
            Fixture = fx;
            var dest = Logic.FlagValue(args, "--snapshot-all");
            SnapshotDest = dest == null ? null : Path.GetFullPath(Token.ExpandPath(dest));
            UsageHistory.Shared.ReplaceSamples((fx.History ?? new List<FixturePoint>()).Select(h =>
                new HistorySample { TimestampUnix = Format.ToUnix(now.AddSeconds(-h.Ago)), Utilization = h.U }));
        }
    }
}
