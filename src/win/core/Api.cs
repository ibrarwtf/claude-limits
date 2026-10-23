using System;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Threading;
using System.Threading.Tasks;

namespace ClaudeLimits
{
    public sealed class Result<T> where T : class
    {
        public T Value { get; }
        public AppError Error { get; }
        Result(T v, AppError e) { Value = v; Error = e; }
        public static Result<T> Ok(T v) => new Result<T>(v, null);
        public static Result<T> Fail(AppError e) => new Result<T>(null, e);
        public bool IsSuccess => Error == null;
    }

    public static class Api
    {
        public static readonly Uri UsageURL = new Uri("https://api.anthropic.com/api/oauth/usage");
        public const string OAuthBeta = "oauth-2025-04-20";

        static readonly HttpClient http = MakeClient();

        static HttpClient MakeClient()
        {
            // .NET Framework only negotiates TLS 1.2+ by default on recent builds;
            // be explicit so older Windows 10 images don't fail the handshake.
            ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
            var c = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
            // HttpClient sends no User-Agent by default; GitHub rejects UA-less calls.
            c.DefaultRequestHeaders.UserAgent.ParseAdd($"claude-limits/{Platform.Version} (Windows)");
            return c;
        }

        internal static HttpClient Http => http;

        /// Returns null when `cancel` fired (a newer manual refresh superseded this
        /// one) — callers drop the result, like NSURLErrorCancelled on the Mac.
        public static async Task<Result<UsageResponse>> FetchUsageAsync(CancellationToken cancel = default)
        {
            string token;
            try { token = await Task.Run(() => Token.LoadAccessToken()).ConfigureAwait(false); }
            catch (AppError e) { return Result<UsageResponse>.Fail(e); }
            catch (Exception e) { return Result<UsageResponse>.Fail(AppError.ParseFailed(e.Message)); }

            var req = new HttpRequestMessage(HttpMethod.Get, UsageURL);
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            req.Headers.Add("anthropic-beta", OAuthBeta);

            using (var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel))
            {
                timeout.CancelAfter(TimeSpan.FromSeconds(10));
                HttpResponseMessage resp;
                string body;
                try
                {
                    resp = await http.SendAsync(req, timeout.Token).ConfigureAwait(false);
                    body = await resp.Content.ReadAsStringAsync().ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    if (cancel.IsCancellationRequested) return null;
                    return Result<UsageResponse>.Fail(AppError.RequestTimeout());
                }
                catch (HttpRequestException e)
                {
                    if (e.InnerException is WebException we)
                    {
                        switch (we.Status)
                        {
                            case WebExceptionStatus.NameResolutionFailure:
                            case WebExceptionStatus.ConnectFailure:
                            case WebExceptionStatus.ConnectionClosed:
                            case WebExceptionStatus.ReceiveFailure:
                            case WebExceptionStatus.SendFailure:
                                return Result<UsageResponse>.Fail(AppError.NetworkUnavailable());
                            case WebExceptionStatus.Timeout:
                                return Result<UsageResponse>.Fail(AppError.RequestTimeout());
                        }
                    }
                    return Result<UsageResponse>.Fail(AppError.ParseFailed(e.InnerException?.Message ?? e.Message));
                }
                catch (Exception e)
                {
                    return Result<UsageResponse>.Fail(AppError.ParseFailed(e.Message));
                }

                using (resp)
                {
                    switch ((int)resp.StatusCode)
                    {
                        case 200: break;
                        case 401: return Result<UsageResponse>.Fail(AppError.AuthFailed());
                        case 403: return Result<UsageResponse>.Fail(AppError.Forbidden());
                        case 429:
                            double? retry = null;
                            var ra = resp.Headers.RetryAfter;
                            if (ra?.Delta != null) retry = ra.Delta.Value.TotalSeconds;
                            else if (ra?.Date != null) retry = Math.Max(0, (ra.Date.Value - DateTimeOffset.UtcNow).TotalSeconds);
                            else if (resp.Headers.TryGetValues("retry-after", out var vals)
                                     && double.TryParse(vals.FirstOrDefault()?.Trim(), out var n)) retry = n;
                            return Result<UsageResponse>.Fail(AppError.RateLimited(retry));
                        default:
                            return Result<UsageResponse>.Fail(AppError.HttpError((int)resp.StatusCode, AppError.Prefix(body, 200)));
                    }
                    if (string.IsNullOrEmpty(body)) return Result<UsageResponse>.Fail(AppError.ParseFailed("empty response"));
                    try { return Result<UsageResponse>.Ok(Json.Parse<UsageResponse>(body)); }
                    catch (Exception e) { return Result<UsageResponse>.Fail(AppError.ParseFailed(e.Message)); }
                }
            }
        }
    }
}
