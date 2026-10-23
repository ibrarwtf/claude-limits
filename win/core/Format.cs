using System;
using System.Globalization;

namespace ClaudeLimits
{
    public static class Format
    {
        /// UTC instant, or null.
        public static DateTime? ParseISO(string s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            if (DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d))
                return d.UtcDateTime;
            return null;
        }

        /// Format the time-remaining string for the pill. Returns null when
        /// there's no active 5-hour window OR the cached resets_at has crossed but
        /// the next poll hasn't refreshed it yet — drop the piece rather than render
        /// a placeholder or a dishonest "0m".
        public static string TimeRemaining(string resetsAt, DateTime? now = null)
        {
            var d = ParseISO(resetsAt);
            if (d == null) return null;
            int total = (int)(d.Value - (now ?? Clock.Now)).TotalSeconds;
            if (total <= 0) return null;
            int h = total / 3600, m = (total % 3600) / 60;
            return h > 0 ? $"{h}:{m:00}" : $"{m}m";
        }

        public static string NextAttempt(int secs)
        {
            if (secs <= 0) return "trying now…";
            if (secs < 60) return $"{secs}s";
            int m = secs / 60, s = secs % 60;
            if (secs < 3600) return $"{m}m {s}s";
            int h = secs / 3600, mr = (secs % 3600) / 60;
            return $"{h}h {mr}m";
        }

        /// Per-second relative time so a per-second timer ticks visibly.
        public static string LiveRelativeTime(DateTime utc, DateTime? now = null)
        {
            int secs = Math.Max(0, (int)((now ?? Clock.Now) - utc).TotalSeconds);
            if (secs < 60) return $"{secs}s ago";
            int m = secs / 60, s = secs % 60;
            if (secs < 3600) return $"{m}m {s}s ago";
            int h = secs / 3600, mr = (secs % 3600) / 60;
            return $"{h}h {mr}m ago";
        }

        /// Wall-clock time ("3:10 PM"). Fixed culture + UTC when the clock is
        /// pinned, so fixture snapshots and spec tests don't depend on the machine.
        public static string ClockTime(DateTime utc) =>
            ClaudeLimits.Clock.IsPinned
                ? utc.ToString("h:mm tt", CultureInfo.GetCultureInfo("en-US"))
                : utc.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);

        /// "Resets @ 3:10 PM · <state-dependent message>" — combines reset clock
        /// with a smoothed burn estimate. The burn rate is time-weighted
        /// (Σ Δpp / Σ Δsec over the current continuous window), NOT an average of
        /// per-pair rates — so Anthropic's lumpy ~5-min updates landing on our
        /// faster poll cadence, sleep/relaunch gaps, and window rollovers can't
        /// inflate it. Mirrors resetLineText in mac/core/Format.swift; covered by
        /// spec/cases.json (`resetLine`).
        public static string ResetLine(UsageBucket f, System.Collections.Generic.IEnumerable<HistorySample> allSamples, DateTime? nowOpt = null)
        {
            var now = nowOpt ?? ClaudeLimits.Clock.Now;
            var resetDate = ParseISO(f.ResetsAt);
            if (resetDate == null) return "No active 5-hour window — starts on your next Claude request";
            if (resetDate.Value <= now) return "Window just reset — refreshing soon";
            var resetClock = ClockTime(resetDate.Value);
            double minutesToReset = Math.Max(0, (resetDate.Value - now).TotalMinutes);

            // Capped state — distinct from the API rate-limit error animation.
            // Reaching 100% naturally is normal end-of-window behaviour, not a
            // failure: surface the countdown instead of burn projections.
            if (f.Utilization >= 99.5)
            {
                int m = (int)minutesToReset, h = m / 60, rem = m % 60;
                return $"Capped — resets in {(h > 0 ? $"{h}h {rem}m" : $"{rem}m")} (@ {resetClock})";
            }

            var samples = System.Linq.Enumerable.ToList(System.Linq.Enumerable.Where(allSamples, x => x.Utilization >= 0));
            if (samples.Count > 30) samples = samples.GetRange(samples.Count - 30, 30);
            if (samples.Count < 3) return $"Resets @ {resetClock} · click to refresh";

            // Time-weighted burn rate over the most recent continuous in-window
            // stretch. A large drop marks a window rollover and a gap far larger
            // than the poll interval (sleep/relaunch) breaks continuity — both
            // reset the accumulation so they can't inflate the rate.
            double maxGap = UsageHistory.PollIntervalSeconds * 2.5;
            double sumPp = 0, sumSec = 0;
            for (int i = 1; i < samples.Count; i++)
            {
                double dPp = samples[i].Utilization - samples[i - 1].Utilization;
                double dSec = samples[i].TimestampUnix - samples[i - 1].TimestampUnix;
                if (dSec <= 0) continue;
                if (dPp < -5 || dSec > maxGap) { sumPp = 0; sumSec = 0; continue; }
                sumPp += Math.Max(0, dPp);   // clamp small downward API jitter to 0
                sumSec += dSec;
            }
            double burnPpHr = sumSec > 0 ? sumPp / sumSec * 3600.0 : 0;
            if (burnPpHr < 0.5)
            {
                // No measurable burn. Distinguish a genuinely idle window from one
                // that's simply too fresh to have moved yet.
                return sumSec < UsageHistory.PollIntervalSeconds * 2
                    ? $"Resets @ {resetClock} · measuring…"
                    : $"Resets @ {resetClock} · idle";
            }

            // Safe pace: the rate that exactly burns the remaining headroom over
            // the remaining window. Below it = will coast in. Above it = early cap.
            double remainingPp = Math.Max(0, 100.0 - f.Utilization);
            double safePpHr = minutesToReset > 0 ? remainingPp / minutesToReset * 60.0 : 0;
            int burnInt = (int)Math.Round(burnPpHr, MidpointRounding.AwayFromZero);
            int safeInt = Math.Max(0, (int)Math.Round(safePpHr, MidpointRounding.AwayFromZero));

            // 5% buffer on the comparison so a steady user doesn't see the warning
            // flap on/off when burn hovers near the safe line.
            if (burnPpHr > safePpHr * 1.05)
            {
                double minsTo100 = remainingPp / burnPpHr * 60.0;
                int h = (int)minsTo100 / 60, m = (int)minsTo100 % 60;
                return $"Resets @ {resetClock} · {burnInt}%/h over safe {safeInt}%/h · 100% in {(h > 0 ? $"{h}h {m}m" : $"{m}m")}";
            }
            return $"Resets @ {resetClock} · {burnInt}%/h · safe ≤ {safeInt}%/h";
        }

        public static double ToUnix(DateTime utc) => (utc - DateTime.SpecifyKind(new DateTime(1970, 1, 1), DateTimeKind.Utc)).TotalSeconds;
        public static DateTime FromUnix(double secs) => new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(secs);
    }
}
