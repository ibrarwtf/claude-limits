using System;

namespace ClaudeLimits
{
    public enum AppErrorKind
    {
        TokenNotFound, ParseFailed, CommandFailed, RateLimited, AuthFailed,
        Forbidden, NetworkUnavailable, RequestTimeout, HttpError,
    }

    // An Exception so token loaders can throw it straight through to the poller,
    // the same way the Swift loaders `throw AppError`.
    public sealed class AppError : Exception
    {
        public AppErrorKind Kind { get; }
        public string Detail { get; }
        public double? RetryAfter { get; }
        public int StatusCode { get; }

        AppError(AppErrorKind kind, string detail = "", double? retryAfter = null, int statusCode = 0)
        {
            Kind = kind; Detail = detail ?? ""; RetryAfter = retryAfter; StatusCode = statusCode;
        }

        public static AppError TokenNotFound() => new AppError(AppErrorKind.TokenNotFound);
        public static AppError ParseFailed(string m) => new AppError(AppErrorKind.ParseFailed, m);
        public static AppError CommandFailed(string m) => new AppError(AppErrorKind.CommandFailed, m);
        public static AppError RateLimited(double? retryAfter) => new AppError(AppErrorKind.RateLimited, retryAfter: retryAfter);
        public static AppError AuthFailed() => new AppError(AppErrorKind.AuthFailed);
        public static AppError Forbidden() => new AppError(AppErrorKind.Forbidden);
        public static AppError NetworkUnavailable() => new AppError(AppErrorKind.NetworkUnavailable);
        public static AppError RequestTimeout() => new AppError(AppErrorKind.RequestTimeout);
        public static AppError HttpError(int code, string body) => new AppError(AppErrorKind.HttpError, body, statusCode: code);

        /// Compact form for the pill / tooltip — keep under ~14 chars.
        public string TitleSymbol
        {
            get
            {
                switch (Kind)
                {
                    case AppErrorKind.TokenNotFound:      return "sign in";
                    case AppErrorKind.ParseFailed:        return "parse";
                    case AppErrorKind.CommandFailed:      return "shell";
                    case AppErrorKind.RateLimited:        return "rate limit";
                    case AppErrorKind.AuthFailed:         return "sign in";
                    case AppErrorKind.Forbidden:          return "403";
                    case AppErrorKind.NetworkUnavailable: return "offline";
                    case AppErrorKind.RequestTimeout:     return "timeout";
                    default:                              return $"HTTP {StatusCode}";
                }
            }
        }

        public string FriendlyMessage
        {
            get
            {
                switch (Kind)
                {
                    case AppErrorKind.TokenNotFound:
                        return "Couldn't find your Claude token. Open Settings and pick a token source.";
                    case AppErrorKind.ParseFailed:
                        return $"Couldn't parse the response: {Detail}";
                    case AppErrorKind.CommandFailed:
                        return $"Shell command failed: {Detail}";
                    case AppErrorKind.RateLimited:
                        if (RetryAfter is double r) return $"Rate limited by Anthropic — retrying in {(int)r} seconds.";
                        return "Rate limited by Anthropic. Will retry shortly.";
                    case AppErrorKind.AuthFailed:
                        return "Your Claude token is invalid or expired. Run `claude` in a terminal to sign back in.";
                    case AppErrorKind.Forbidden:
                        return "Access forbidden. Your account may not have access to the usage API.";
                    case AppErrorKind.NetworkUnavailable:
                        return "Couldn't reach api.anthropic.com — check your internet connection.";
                    case AppErrorKind.RequestTimeout:
                        return "Request to Anthropic timed out. Will try again on the next poll.";
                    default:
                        return $"Anthropic returned HTTP {StatusCode}. {Prefix(Detail, 120)}";
                }
            }
        }

        public override string Message => FriendlyMessage;

        internal static string Prefix(string s, int n) => s == null ? "" : (s.Length <= n ? s : s.Substring(0, n));
    }
}
