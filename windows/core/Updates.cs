using System;
using System.Linq;
using System.Net.Http;
using System.Runtime.Serialization;
using System.Threading.Tasks;

namespace ClaudeLimits
{
    [DataContract]
    public sealed class GitHubAsset
    {
        [DataMember(Name = "name", EmitDefaultValue = false)] public string Name { get; set; }
        [DataMember(Name = "browser_download_url", EmitDefaultValue = false)] public string DownloadUrl { get; set; }
        /// "sha256:<hex>" on assets uploaded since mid-2025; absent on older ones.
        [DataMember(Name = "digest", EmitDefaultValue = false)] public string Digest { get; set; }
    }

    [DataContract]
    public sealed class GitHubRelease
    {
        [DataMember(Name = "tag_name", EmitDefaultValue = false)] public string TagName { get; set; }
        [DataMember(Name = "draft", EmitDefaultValue = false)] public bool Draft { get; set; }
        [DataMember(Name = "prerelease", EmitDefaultValue = false)] public bool Prerelease { get; set; }
        [DataMember(Name = "assets", EmitDefaultValue = false)] public GitHubAsset[] Assets { get; set; }

        public GitHubAsset WindowsAsset => Assets?.FirstOrDefault(a =>
            a.Name != null && a.Name.StartsWith("claude-limits-windows-", StringComparison.OrdinalIgnoreCase)
                           && a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
    }

    public static class Updates
    {
        /// The full list, not /releases/latest: v0.3.0 shipped Windows-only and
        /// isn't marked latest, and scanning for the newest release that actually
        /// carries a Windows zip stays correct whichever release is "latest".
        public static readonly Uri ReleasesURL = new Uri("https://api.github.com/repos/ibrarwtf/claude-limits/releases?per_page=30");
        public const string ReleasesPage = "https://github.com/ibrarwtf/claude-limits/releases";

        /// Newest published release that carries a Windows zip, or null if none.
        public static async Task<GitHubRelease> FetchLatestReleaseAsync()
        {
            var req = new HttpRequestMessage(HttpMethod.Get, ReleasesURL);
            req.Headers.Accept.ParseAdd("application/vnd.github+json");
            using (var cts = new System.Threading.CancellationTokenSource(TimeSpan.FromSeconds(10)))
            using (var resp = await Api.Http.SendAsync(req, cts.Token).ConfigureAwait(false))
            {
                var body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                if (!resp.IsSuccessStatusCode)
                    throw new Exception($"GitHub returned HTTP {(int)resp.StatusCode}");
                var all = Json.Parse<GitHubRelease[]>(body) ?? new GitHubRelease[0];
                return all.Where(r => !r.Draft && !r.Prerelease && r.WindowsAsset != null && r.TagName != null)
                          .OrderByDescending(r => r.TagName, Comparer)
                          .FirstOrDefault();
            }
        }

        static readonly System.Collections.Generic.IComparer<string> Comparer =
            System.Collections.Generic.Comparer<string>.Create((a, b) =>
                IsNewerVersion(a, b) ? 1 : IsNewerVersion(b, a) ? -1 : 0);

        /// Compare two semver-ish strings ("v0.1.4", "0.1.10"). Strips a leading "v",
        /// splits on ".", compares numerically. Missing components count as 0.
        public static bool IsNewerVersion(string latest, string current)
        {
            int[] Parse(string s)
            {
                var stripped = s.StartsWith("v") ? s.Substring(1) : s;
                return stripped.Split('.').Select(p => int.TryParse(p, out var n) ? (int?)n : null)
                               .Where(n => n.HasValue).Select(n => n.Value).ToArray();
            }
            var l = Parse(latest); var c = Parse(current);
            for (int i = 0; i < Math.Max(l.Length, c.Length); i++)
            {
                int a = i < l.Length ? l[i] : 0, b = i < c.Length ? c[i] : 0;
                if (a > b) return true;
                if (a < b) return false;
            }
            return false;
        }
    }
}
