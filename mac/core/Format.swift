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
func formatTimeRemaining(_ resetsAt: String?, now: Date = Clock.now()) -> String? {
    guard let d = parseISO(resetsAt) else { return nil }
    let total = Int(d.timeIntervalSince(now))
    guard total > 0 else { return nil }
    let h = total / 3600, m = (total % 3600) / 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "\(m)m"
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
func liveRelativeTime(_ date: Date, now: Date = Clock.now()) -> String {
    let secs = max(0, Int(now.timeIntervalSince(date)))
    if secs < 60 { return "\(secs)s ago" }
    let m = secs / 60, s = secs % 60
    if secs < 3600 { return "\(m)m \(s)s ago" }
    let h = secs / 3600, mr = (secs % 3600) / 60
    return "\(h)h \(mr)m ago"
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

/// "Resets @ 3:10 PM · <state-dependent message>" — combines reset clock
/// with a smoothed burn estimate. The burn rate is time-weighted
/// (Σ Δpp / Σ Δsec over the current continuous window), NOT an average of
/// per-pair rates — so Anthropic's lumpy ~5-min updates landing on our
/// faster poll cadence, sleep/relaunch gaps, and window rollovers can't
/// inflate it. Covered by spec/cases.json (`resetLine`).
func resetLineText(_ f: UsageBucket, samples allSamples: [HistorySample], now: Date = Clock.now()) -> String {
    guard let resetDate = parseISO(f.resetsAt) else {
        return "No active 5-hour window — starts on your next Claude request"
    }
    guard resetDate > now else {
        return "Window just reset — refreshing soon"
    }
    let resetClock = formatClock(resetDate)
    let minutesToReset = max(0, resetDate.timeIntervalSince(now) / 60.0)

    // Capped state — distinct from the API rate-limit error animation.
    // Reaching 100% naturally is normal end-of-window behaviour, not a
    // failure: surface the countdown instead of burn projections.
    if f.utilization >= 99.5 {
        let m = Int(minutesToReset)
        let h = m / 60, rem = m % 60
        let when = h > 0 ? "\(h)h \(rem)m" : "\(rem)m"
        return "Capped — resets in \(when) (@ \(resetClock))"
    }

    let samples = Array(allSamples.filter { $0.utilization >= 0 }.suffix(30))
    if samples.count < 3 {
        return "Resets @ \(resetClock) · click to refresh"
    }
    // Time-weighted burn rate over the most recent continuous in-window
    // stretch: Σ(Δpp) / Σ(Δsec), NOT a mean of per-pair rates. Dividing the
    // window's net change by its net elapsed time is robust to Anthropic's
    // lumpy ~5-min updates landing on our faster poll cadence (a "catch-up"
    // jump is divided by the real elapsed time, not one poll interval). A
    // large drop marks a window rollover and a gap far larger than the poll
    // interval (sleep/relaunch) breaks continuity — both reset the
    // accumulation so they can't inflate the rate.
    let maxGap = pollIntervalSeconds * 2.5
    var sumPp = 0.0, sumSec = 0.0
    for i in 1..<samples.count {
        let dPp = samples[i].utilization - samples[i-1].utilization
        let dSec = samples[i].timestamp.timeIntervalSince(samples[i-1].timestamp)
        if dSec <= 0 { continue }
        if dPp < -5 || dSec > maxGap { sumPp = 0; sumSec = 0; continue }
        sumPp += max(0, dPp)   // clamp small downward API jitter to 0
        sumSec += dSec
    }
    let burnPpHr = sumSec > 0 ? sumPp / sumSec * 3600.0 : 0
    if burnPpHr < 0.5 {
        // No measurable burn. Distinguish a genuinely idle window from one
        // that's simply too fresh to have moved yet (just after a reset the
        // API's ~5-min value hasn't ticked, so zero deltas aren't "idle").
        return sumSec < pollIntervalSeconds * 2
            ? "Resets @ \(resetClock) · measuring…"
            : "Resets @ \(resetClock) · idle"
    }

    // Safe pace: the rate that exactly burns the remaining headroom over
    // the remaining window. Below it = will coast in. Above it = early cap.
    let remainingPp = max(0, 100.0 - f.utilization)
    let safePpHr = minutesToReset > 0 ? remainingPp / minutesToReset * 60.0 : 0
    let burnInt = Int(round(burnPpHr))
    let safeInt = max(0, Int(round(safePpHr)))

    // 5% buffer on the comparison so a steady user doesn't see the warning
    // flap on/off when burn hovers near the safe line.
    if burnPpHr > safePpHr * 1.05 {
        let minsTo100 = remainingPp / burnPpHr * 60.0
        let h = Int(minsTo100) / 60, m = Int(minsTo100) % 60
        let when = h > 0 ? "\(h)h \(m)m" : "\(m)m"
        return "Resets @ \(resetClock) · \(burnInt)%/h over safe \(safeInt)%/h · 100% in \(when)"
    }
    return "Resets @ \(resetClock) · \(burnInt)%/h · safe ≤ \(safeInt)%/h"
}
