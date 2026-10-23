using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.Serialization;
using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    [DataContract]
    public sealed class HistorySample
    {
        [DataMember(Name = "t")] public double TimestampUnix { get; set; }
        [DataMember(Name = "u")] public double Utilization { get; set; }
        public DateTime Timestamp => Format.FromUnix(TimestampUnix);
    }

    /// Burn-rate samples on disk. Rollover, sparkline and burn maths live in
    /// logic/core.pl.
    public sealed class UsageHistory
    {
        /// Off in fixture mode and spec tests so they never touch the real history file.
        public static bool Persist = true;
        // Lazy so Persist can be cleared before the first load from disk.
        static readonly Lazy<UsageHistory> shared = new Lazy<UsageHistory>(() => new UsageHistory());
        public static UsageHistory Shared => shared.Value;
        List<HistorySample> samples = new List<HistorySample>();
        public IReadOnlyList<HistorySample> Samples => samples;
        /// In-memory only: after a relaunch the big-drop fallback covers a missed reset.
        string lastResetsAt;
        readonly string path = Path.Combine(Platform.DataDir, "history.json");

        UsageHistory()
        {
            try { if (Persist && File.Exists(path)) samples = Json.Parse<HistorySample[]>(File.ReadAllBytes(path)).ToList(); } catch { }
        }

        public void Append(double utilization, string resetsAt)
        {
            if (Rollover(samples.LastOrDefault()?.Utilization, utilization, lastResetsAt, resetsAt, Clock.Now)) samples.Clear();
            if (resetsAt != null) lastResetsAt = resetsAt;
            Add(utilization);
        }

        /// A failed poll is a utilization = -1 sentinel; the logic skips it.
        public void AppendError() => Add(-1);

        void Add(double utilization)
        {
            samples.Add(new HistorySample { TimestampUnix = Format.ToUnix(Clock.Now), Utilization = utilization });
            if (samples.Count > MaxSamples) samples.RemoveRange(0, samples.Count - MaxSamples);
            if (Persist) try { Json.WriteFileAtomic(path, Json.Write(samples.ToArray())); } catch { }
        }

        /// Fixture mode / spec tests: start from a known sample set.
        public void ReplaceSamples(IEnumerable<HistorySample> s)
        {
            samples = s.ToList();
            lastResetsAt = null;
        }
    }
}
