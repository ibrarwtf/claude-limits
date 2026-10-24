using System;
using System.Globalization;

namespace ClaudeLimits
{
    /// Date plumbing the generated Logic.cs calls into (formatting rules live
    /// in logic/core.pl).
    public static class Format
    {
        /// UTC instant, or null.
        public static DateTime? ParseISO(string s) =>
            DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d.UtcDateTime : (DateTime?)null;

        /// Wall-clock time ("3:10 PM"). Fixed culture + UTC when the clock is
        /// pinned, so fixture snapshots and spec tests don't depend on the machine.
        public static string ClockTime(DateTime utc) =>
            Clock.IsPinned
                ? utc.ToString("h:mm tt", CultureInfo.GetCultureInfo("en-US"))
                : utc.ToLocalTime().ToString("t", CultureInfo.CurrentCulture);

        public static double ToUnix(DateTime utc) => (utc - DateTime.SpecifyKind(new DateTime(1970, 1, 1), DateTimeKind.Utc)).TotalSeconds;
        public static DateTime FromUnix(double secs) => new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(secs);
    }
}
