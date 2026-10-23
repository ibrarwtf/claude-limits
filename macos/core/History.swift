import Foundation

struct HistorySample: Codable {
    let timestamp: Date
    let utilization: Double
}

final class UsageHistory {
    /// Off in fixture mode and spec tests so they never touch the real history file.
    static var persist = true
    static let shared = UsageHistory()
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
        if rollover(samples.last?.utilization, utilization, lastResetsAt, resetsAt, Clock.now()) {
            samples.removeAll()
        }
        if let resetsAt = resetsAt { lastResetsAt = resetsAt }
        samples.append(HistorySample(timestamp: Clock.now(), utilization: utilization))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save()
    }

    /// Record a failed poll as utilization = -1 sentinel; renderers ignore it.
    func appendError() {
        samples.append(HistorySample(timestamp: Clock.now(), utilization: -1))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
        save()
    }

    /// Fixture mode / spec tests: start from a known sample set.
    func replaceSamples(_ s: [HistorySample]) {
        samples = s
        lastResetsAt = nil
    }

    func load() {
        guard UsageHistory.persist else { return }
        guard let data = try? Data(contentsOf: url),
              let s = try? JSONDecoder().decode([HistorySample].self, from: data) else { return }
        samples = s
    }

    func save() {
        guard UsageHistory.persist else { return }
        guard let data = try? JSONEncoder().encode(samples) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
