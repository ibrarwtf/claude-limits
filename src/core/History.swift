import Foundation

struct HistorySample: Codable {
    let timestamp: Date
    let utilization: Double
}

/// Hardcoded poll interval. Anthropic's usage API doesn't change quickly enough
/// to merit faster polling, and slower polling makes the menu bar feel stale.
let pollIntervalSeconds: TimeInterval = 120.0

final class UsageHistory {
    static let shared = UsageHistory()
    private let maxSamples = 60
    private(set) var samples: [HistorySample] = []
    private let url: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("claude-limits", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    func append(utilization: Double, resetsAt: String?) {
        if let last = samples.last, let resetDate = parseISO(resetsAt) {
            // 5-hour window reset detected: drop history. Guard against
            // error-sentinel last samples (utilization == -1).
            if last.utilization >= 0 && last.utilization > utilization + 5 && resetDate > Date() {
                samples.removeAll()
            }
        }
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

    /// Bars represent *burn rate* between consecutive samples (percentage points
    /// consumed since the last poll), not absolute utilization. Scaling:
    /// 0..3pp/sample → ▁..█; spikes above 3pp clamp to █.
    func sparkline(width: Int = 10) -> String {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        let recent = Array(samples.filter { $0.utilization >= 0 }.suffix(width + 1))
        let deltaCount = max(0, recent.count - 1)
        let pad = max(0, width - deltaCount)
        let padding = String(repeating: "▁", count: pad)
        if deltaCount == 0 { return padding }
        var line = ""
        for i in 1..<recent.count {
            let delta = recent[i].utilization - recent[i-1].utilization
            let clamped = max(0.0, min(delta, 3.0))
            let idx = min(7, max(0, Int(round(clamped / 3.0 * 7))))
            line.append(bars[idx])
        }
        // Left-pad so the newest bar is anchored at the right edge of the slot.
        return padding + line
    }
}
