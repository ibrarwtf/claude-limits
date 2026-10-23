using System;
using System.Linq;
using System.Net.Http;
using System.Collections.Generic;
using System.Threading.Tasks;
using static ClaudeLimits.Logic;

namespace ClaudeLimits
{
    // GitHubRelease / GitHubAsset are generated from logic/core.pl (Logic.cs).
    public static class Updates
    {
        /// The full list, not /releases/latest — see newest_windows in logic/core.pl.
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
                return NewestWindows(Json.Parse<List<GitHubRelease>>(body) ?? new List<GitHubRelease>());
            }
        }
    }
}
