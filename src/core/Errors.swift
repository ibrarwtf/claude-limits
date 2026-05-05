import Foundation

enum AppError: LocalizedError {
    case tokenNotFound
    case parseFailed(String)
    case commandFailed(String)
    case rateLimited(retryAfter: TimeInterval?)
    case authFailed
    case forbidden
    case networkUnavailable
    case requestTimeout
    case httpError(Int, String)

    /// Compact form for the menu bar title — keep under ~14 chars.
    var titleSymbol: String {
        switch self {
        case .tokenNotFound:      return "sign in"
        case .parseFailed:        return "parse"
        case .commandFailed:      return "shell"
        case .rateLimited:        return "rate limit"
        case .authFailed:         return "sign in"
        case .forbidden:          return "403"
        case .networkUnavailable: return "offline"
        case .requestTimeout:     return "timeout"
        case .httpError(let c,_): return "HTTP \(c)"
        }
    }

    var friendlyMessage: String {
        switch self {
        case .tokenNotFound:
            return "Couldn't find your Claude token. Open Settings and pick a token source."
        case .parseFailed(let m):
            return "Couldn't parse the response: \(m)"
        case .commandFailed(let m):
            return "Shell command failed: \(m)"
        case .rateLimited(let r):
            if let r = r { return "Rate limited by Anthropic — retrying in \(Int(r)) seconds." }
            return "Rate limited by Anthropic. Will retry shortly."
        case .authFailed:
            return "Your Claude token is invalid or expired. Run `claude` in a terminal to sign back in."
        case .forbidden:
            return "Access forbidden. Your account may not have access to the usage API."
        case .networkUnavailable:
            return "Couldn't reach api.anthropic.com — check your internet connection."
        case .requestTimeout:
            return "Request to Anthropic timed out. Will try again on the next poll."
        case .httpError(let c, let body):
            return "Anthropic returned HTTP \(c). \(body.prefix(120))"
        }
    }

    var errorDescription: String? { friendlyMessage }
}
