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
        public static string TimeRemaining(string resetsAt)
        {
            var d = ParseISO(resetsAt);
            if (d == null) return null;
            int total = (int)(d.Value - DateTime.UtcNow).TotalSeconds;
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
        public static string LiveRelativeTime(DateTime utc)
        {
            int secs = Math.Max(0, (int)(DateTime.UtcNow - utc).TotalSeconds);
            if (secs < 60) return $"{secs}s ago";
            int m = secs / 60, s = secs % 60;
            if (secs < 3600) return $"{m}m {s}s ago";
            int h = secs / 3600, mr = (secs % 3600) / 60;
            return $"{h}h {mr}m ago";
        }

        public static double ToUnix(DateTime utc) => (utc - DateTime.SpecifyKind(new DateTime(1970, 1, 1), DateTimeKind.Utc)).TotalSeconds;
        public static DateTime FromUnix(double secs) => new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(secs);
    }
}
