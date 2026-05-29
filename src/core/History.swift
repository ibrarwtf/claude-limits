import Foundation

struct HistorySample: Codable {
    let timestamp: Date
    let utilization: Double
}

/// Hardcoded poll interval. Anthropic's usage endpoint only recomputes its
/// utilization on its own ~5-minute cadence, so polling faster than that buys
/// no freshness — it just multiplies API calls and rate-limit exposure. 180s
/// stays comfortably under that cadence (no systematic lag) while cutting our
/// call volume ~1/3 vs the old 120s. The reset countdown is derived locally
/// and ticked every 30s, so a slower poll doesn't make it feel stale.
let pollIntervalSeconds: TimeInterval = 180.0

final class UsageHistory {
    static let shared = UsageHistory()
    private let maxSamples = 60
    private(set) var samples: [HistorySample] = []
    /// Last `resets_at` we've seen, for authoritative window-rollover detection.
    /// In-memory only: on relaunch the utilization-drop fallback covers a reset
    /// that happened while we were down.
    private var lastResetsAt: String?
    private let url: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("claude-limits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    func append(utilization: Double, resetsAt: String?) {
        if let last = samples.last, last.utilization >= 0,
           let resetDate = parseISO(resetsAt), resetDate > Date() {
            // Window-rollover detection → drop history. Primary signal is
            // authoritative: the API's resets_at advanced to a new future
            // instant. Fallback (a large utilization drop) covers a reset that
            // happened while we were down, where there's no prior resets_at to
            // compare — at the cost of missing rollovers from <=5% utilization,
            // which the resets_at signal catches whenever the app was running.
            let resetsAtAdvanced = resetsAt != nil && lastResetsAt != nil && resetsAt != lastResetsAt
            let bigDrop = last.utilization > utilization + 5
            if resetsAtAdvanced || bigDrop {
                samples.removeAll()
            }
        }
        if let resetsAt = resetsAt { lastResetsAt = resetsAt }
        samples.append(HistorySample(timestamp: Date(), utilization: utilization))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save()
    }

    /// Record a failed poll as utilization = -1 sentinel; renderers ignore it.
    func appendError() {
        samples.append(HistorySample(timestamp: Date(), utilization: -1))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save()
    }

    func load() {
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
        samples = s
    }

    func save() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Bars represent *burn rate* between consecutive samples — the change in
    /// utilization normalized by elapsed time and re-expressed as pp-per-poll-
    /// interval, NOT the raw per-sample delta. Without the time normalization a
    /// sleep/relaunch gap (two far-apart samples) would render a misleading
    /// full-height spike. Scaling: 0..3 pp/interval → ▁..█; above that clamps to █.
    func sparkline(width: Int = 10) -> String {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let recent = Array(samples.filter { $0.utilization >= 0 }.suffix(width + 1))
        let deltaCount = max(0, recent.count - 1)
        let pad = max(0, width - deltaCount)
        let padding = String(repeating: "▁", count: pad)
        if deltaCount == 0 { return padding }
        var line = ""
        for i in 1..<recent.count {
            let dPp = recent[i].utilization - recent[i-1].utilization
            let dSec = recent[i].timestamp.timeIntervalSince(recent[i-1].timestamp)
            // Normalize to a rate, then express as pp-per-poll-interval so the
            // 0..3 scale still reads naturally for a normal-cadence poll while a
            // long gap (large dSec) collapses to a low bar.
            let perInterval = (dPp > 0 && dSec > 0) ? dPp / dSec * pollIntervalSeconds : 0.0
            let clamped = max(0.0, min(perInterval, 3.0))
            let idx = min(7, max(0, Int(round(clamped / 3.0 * 7))))
            line.append(bars[idx])
        }
        // Left-pad so the newest bar is anchored at the right edge of the slot.
        return padding + line
    }
}
