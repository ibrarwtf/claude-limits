using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Web.Script.Serialization;

using static ClaudeLimits.Logic;

namespace ClaudeLimits.Spec
{
    /// spec/cases.json runner for the Windows core. macos/tests/main.swift is the
    /// same runner for the Mac core — keep the two in step.
    static class Program
    {
        static int passed, failed;
        static DateTime now;

        static int Main(string[] args)
        {
            var path = args.Length > 0 ? args[0] : Path.Combine("spec", "cases.json");
            var root = (Dictionary<string, object>)new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path));
            now = Format.ParseISO((string)root["now"]).Value;
            Clock.Pinned = now;
            UsageHistory.Persist = false;
            Settings.InMemory = true;

            foreach (var c in Cases(root, "timeRemaining"))
            {
                var resetsAt = c["resetsIn"] == null ? null : Iso(now.AddSeconds(Num(c["resetsIn"])));
                Check($"timeRemaining {c["resetsIn"] ?? "null"}", Countdown(resetsAt, now), (string)c["expect"]);
            }
            foreach (var c in Cases(root, "nextAttempt"))
                Check($"nextAttempt {c["secs"]}", NextAttempt((int)Num(c["secs"])), (string)c["expect"]);
            foreach (var c in Cases(root, "relativeTime"))
                Check($"relativeTime {c["ago"]}", RelativeTime(now.AddSeconds(-Num(c["ago"])), now), (string)c["expect"]);
            foreach (var c in Cases(root, "isNewerVersion"))
                Check($"isNewerVersion {c["latest"]} > {c["current"]}",
                    IsNewerVersion((string)c["latest"], (string)c["current"]).ToString().ToLowerInvariant(),
                    ((bool)c["expect"]).ToString().ToLowerInvariant());
            foreach (var c in Cases(root, "extractToken"))
                Check($"extractToken {Short((string)c["text"])}", Token.ExtractTokenFromText((string)c["text"]), (string)c["expect"]);
            foreach (var c in Cases(root, "sparkline"))
            {
                Check($"sparkline: {c["name"]}", Sparkline(Samples(c["samples"]), (int)Num(c["width"])), (string)c["expect"]);
            }
            foreach (var c in Cases(root, "resetLine"))
            {
                var resetsAt = c["resetsIn"] == null ? null : Iso(now.AddSeconds(Num(c["resetsIn"])));
                Check($"resetLine: {c["name"]}", ResetLine(Num(c["utilization"]), resetsAt, Samples(c["samples"]), now), (string)c["expect"]);
            }
            foreach (var c in Cases(root, "weeklyRows"))
            {
                var json = new JavaScriptSerializer().Serialize(c["response"]);
                var got = string.Join(", ", WeeklyRows(Json.Parse<UsageResponse>(json)).Select(r => $"{r.Label}={Percent(r.Utilization)}"));
                Check($"weeklyRows: {c["name"]}", got, (string)c["expect"]);
            }
            foreach (var c in Cases(root, "rollover"))
            {
                UsageHistory.Shared.ReplaceSamples(new HistorySample[0]);
                foreach (var stepObj in (object[])c["steps"])
                {
                    var step = (Dictionary<string, object>)stepObj;
                    Clock.Pinned = now.AddSeconds(Num(step["t"]));
                    UsageHistory.Shared.Append(Num(step["u"]), Iso(now.AddSeconds(Num(step["r"]))));
                }
                Clock.Pinned = now;
                Check($"rollover: {c["name"]}", UsageHistory.Shared.Samples.Count.ToString(), Num(c["expectCount"]).ToString(CultureInfo.InvariantCulture));
            }

            Console.WriteLine($"windows spec: {passed} passed, {failed} failed");
            return failed == 0 ? 0 : 1;
        }

        static IEnumerable<Dictionary<string, object>> Cases(Dictionary<string, object> root, string key) =>
            ((object[])root[key]).Cast<Dictionary<string, object>>();

        static double Num(object o) => Convert.ToDouble(o, CultureInfo.InvariantCulture);

        static string Iso(DateTime utc) => utc.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);

        static IReadOnlyList<HistorySample> Samples(object arr) =>
            ((object[])arr).Cast<object[]>().Select(p => new HistorySample
            {
                TimestampUnix = Format.ToUnix(now.AddSeconds(-Num(p[0]))),
                Utilization = Num(p[1]),
            }).ToList();

        static string Short(string s) => s.Length > 24 ? s.Substring(0, 24) + "…" : s.Replace("\n", "\\n");

        static void Check(string name, string got, string want)
        {
            if (got == want) { passed++; return; }
            failed++;
            Console.WriteLine($"FAIL {name}\n  got:  {Show(got)}\n  want: {Show(want)}");
        }

        static string Show(string s) => s == null ? "null" : $"\"{s}\"";
    }
}
