import Foundation

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// Wall-clock time ("3:10 PM"). Fixed locale + UTC when the clock is pinned, so
/// fixture snapshots and spec tests don't depend on the machine's settings
/// (and dodge ICU's narrow no-break space before AM/PM).
func formatClock(_ d: Date) -> String {
    let df = DateFormatter()
    if Clock.isPinned {
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "h:mm a"
    } else {
        df.timeStyle = .short
        df.dateStyle = .none
    }
    return df.string(from: d)
}
