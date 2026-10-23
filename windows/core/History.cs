using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;

namespace ClaudeLimits
{
    [DataContract]
    public sealed class HistorySample
    {
        [DataMember(Name = "t")] public double TimestampUnix { get; set; }
        [DataMember(Name = "u")] public double Utilization { get; set; }
        public DateTime Timestamp => Format.FromUnix(TimestampUnix);
    }

    public sealed class UsageHistory
    {
        /// Hardcoded poll interval. Anthropic's usage endpoint only recomputes its
        /// utilization on its own ~5-minute cadence, so polling faster than that buys
        /// no freshness — it just multiplies API calls and rate-limit exposure. 180s
        /// stays comfortably under that cadence (no systematic lag). The reset
        /// countdown is derived locally and ticked every 30s, so a slower poll
        /// doesn't make it feel stale.
        public const double PollIntervalSeconds = 180.0;

        /// Off in fixture mode and spec tests so they never touch the real history file.
        public static bool Persist = true;
        // Lazy so Persist can be cleared before the first load from disk.
        static readonly Lazy<UsageHistory> shared = new Lazy<UsageHistory>(() => new UsageHistory());
        public static UsageHistory Shared => shared.Value;
        const int maxSamples = 60;
        List<HistorySample> samples = new List<HistorySample>();
        public IReadOnlyList<HistorySample> Samples => samples;
        /// Last `resets_at` we've seen, for authoritative window-rollover detection.
        /// In-memory only: on relaunch the utilization-drop fallback covers a reset
        /// that happened while we were down.
        string lastResetsAt;
        readonly string path = System.IO.Path.Combine(Platform.DataDir, "history.json");

        UsageHistory() { Load(); }

        public void Append(double utilization, string resetsAt)
        {
            var last = samples.LastOrDefault();
            var resetDate = Format.ParseISO(resetsAt);
            if (last != null && last.Utilization >= 0 && resetDate != null && resetDate > Clock.Now)
            {
                // Window-rollover detection → drop history. Primary signal is
                // authoritative: the API's resets_at advanced to a new future
                // instant. Fallback (a large utilization drop) covers a reset that
                // happened while we were down, where there's no prior resets_at to
                // compare — at the cost of missing rollovers from <=5% utilization,
                // which the resets_at signal catches whenever the app was running.
                bool resetsAtAdvanced = resetsAt != null && lastResetsAt != null && resetsAt != lastResetsAt;
                bool bigDrop = last.Utilization > utilization + 5;
                if (resetsAtAdvanced || bigDrop) samples.Clear();
            }
            if (resetsAt != null) lastResetsAt = resetsAt;
            Add(utilization);
        }

        /// Record a failed poll as utilization = -1 sentinel; renderers ignore it.
        public void AppendError() => Add(-1);

        void Add(double utilization)
        {
            samples.Add(new HistorySample { TimestampUnix = Format.ToUnix(Clock.Now), Utilization = utilization });
            if (samples.Count > maxSamples) samples.RemoveRange(0, samples.Count - maxSamples);
            Save();
        }

        /// Fixture mode / spec tests: start from a known sample set.
        public void ReplaceSamples(IEnumerable<HistorySample> s)
        {
            samples = s.ToList();
            lastResetsAt = null;
        }

        public void Load()
        {
            if (!Persist) return;
            try
            {
                if (!File.Exists(path)) return;
                var s = Json.Parse<HistorySample[]>(File.ReadAllBytes(path));
                if (s != null) samples = s.ToList();
            }
            catch { }
        }

        public void Save()
        {
            if (!Persist) return;
            try { Json.WriteFileAtomic(path, Json.Write(samples.ToArray())); } catch { }
        }

        static readonly string bars = "▁▂▃▄▅▆▇█";

        /// Bars represent *burn rate* between consecutive samples — the change in
        /// utilization normalized by elapsed time and re-expressed as pp-per-poll-
        /// interval, NOT the raw per-sample delta. Without the time normalization a
        /// sleep/relaunch gap (two far-apart samples) would render a misleading
        /// full-height spike. Scaling: 0..3 pp/interval → ▁..█; above that clamps to █.
        public string Sparkline(int width = 10)
        {
            var recent = samples.Where(x => x.Utilization >= 0).ToList();
            if (recent.Count > width + 1) recent = recent.Skip(recent.Count - (width + 1)).ToList();
            int deltaCount = Math.Max(0, recent.Count - 1);
            var padding = new string('▁', Math.Max(0, width - deltaCount));
            if (deltaCount == 0) return padding;
            var line = new System.Text.StringBuilder();
            for (int i = 1; i < recent.Count; i++)
            {
                double dPp = recent[i].Utilization - recent[i - 1].Utilization;
                double dSec = recent[i].TimestampUnix - recent[i - 1].TimestampUnix;
                // Normalize to a rate, then express as pp-per-poll-interval so the
                // 0..3 scale still reads naturally for a normal-cadence poll while a
                // long gap (large dSec) collapses to a low bar.
                double perInterval = (dPp > 0 && dSec > 0) ? dPp / dSec * PollIntervalSeconds : 0.0;
                double clamped = Math.Max(0.0, Math.Min(perInterval, 3.0));
                int idx = Math.Min(7, Math.Max(0, (int)Math.Round(clamped / 3.0 * 7, MidpointRounding.AwayFromZero)));
                line.Append(bars[idx]);
            }
            // Left-pad so the newest bar is anchored at the right edge of the slot.
            return padding + line;
        }
    }
}
