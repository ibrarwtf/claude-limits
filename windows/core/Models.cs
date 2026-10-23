using System.Collections.Generic;
using System.Linq;

namespace ClaudeLimits
{
    // The response types are generated from logic/core.pl (Logic.cs).
    public static partial class Logic
    {
        /// Rows for the flyout's "Weekly limits" section. Falls back to the newer
        /// `limits` array when every seven_day* bucket is null. Mirrors weeklyRows
        /// in macos/core/Models.swift; covered by spec/cases.json (`weeklyRows`).
        public static List<(string label, UsageBucket bucket)> WeeklyRows(UsageResponse r)
        {
            var legacy = new (string, UsageBucket)[]
            {
                ("Overall", r.SevenDay),
                ("Opus", r.SevenDayOpus),
                ("Sonnet", r.SevenDaySonnet),
                ("OAuth apps", r.SevenDayOauthApps),
                ("Cowork", r.SevenDayCowork),
                ("Claude Design", r.SevenDayOmelette),
            }.Where(x => x.Item2 != null).ToList();
            if (legacy.Count > 0) return legacy;
            return (r.Limits ?? new UsageLimit[0])
                .Where(l => l.Group == "weekly" && l.Percent.HasValue)
                .Select(l => (l.Scope?.Model?.DisplayName ?? "Overall",
                              new UsageBucket { UtilizationRaw = l.Percent, ResetsAt = l.ResetsAt }))
                .ToList();
        }
    }
}
