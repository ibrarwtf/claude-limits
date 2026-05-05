import Foundation

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// Format the time-remaining string for the menu-bar widget. Returns nil when
/// there's no active 5-hour window OR the cached resets_at has crossed but
/// the next poll hasn't refreshed it yet — drop the piece rather than render
/// a placeholder or a dishonest "0m".
func formatTimeRemaining(_ resetsAt: String?) -> String? {
    guard let d = parseISO(resetsAt) else { return nil }
    let total = Int(d.timeIntervalSinceNow)
    guard total > 0 else { return nil }
    let h = total / 3600, m = (total % 3600) / 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "\(m)m"
}

func progressBar(_ pct: Double, width: Int = 18) -> String {
    let p = max(0, min(100, pct))
    let filled = Int(round(Double(width) * p / 100.0))
    return String(repeating: "■", count: filled) + String(repeating: "□", count: width - filled)
}

func formatNextAttempt(_ secs: Int) -> String {
    if secs <= 0 { return "trying now…" }
    if secs < 60 { return "\(secs)s" }
    let m = secs / 60, s = secs % 60
    if secs < 3600 { return "\(m)m \(s)s" }
    let h = secs / 3600, mr = (secs % 3600) / 60
    return "\(h)h \(mr)m"
}

/// Per-second relative time so a per-second timer ticks visibly.
func liveRelativeTime(_ date: Date) -> String {
    let secs = max(0, Int(-date.timeIntervalSinceNow))
    if secs < 60 { return "\(secs)s ago" }
    let m = secs / 60, s = secs % 60
    if secs < 3600 { return "\(m)m \(s)s ago" }
    let h = secs / 3600, mr = (secs % 3600) / 60
    return "\(h)h \(mr)m ago"
}
