import Foundation

/// The app's notion of "now". Normally the wall clock; pinned in fixture mode
/// so countdowns, "Xs ago" and the reset clock render identically every run.
enum Clock {
    static var pinned: Date? = nil
    static var isPinned: Bool { pinned != nil }
    static func now() -> Date { pinned ?? Date() }
}

// Fixture / FixturePoint are generated from logic/core.pl (Logic.swift).

/// `--fixture <file>` loads a Fixture instead of polling Anthropic and keeps
/// settings/history off disk; `--snapshot-all <dir>` then renders every view
/// to PNG and exits. This is how CI (no Claude login, no human at the screen)
/// produces snapshots/macos/ deterministically.
enum FixtureMode {
    private(set) static var fixture: Fixture?
    private(set) static var snapshotDest: String?
    static var isActive: Bool { fixture != nil }

    struct ConfigError: Error, CustomStringConvertible { let description: String }

    /// Must run before anything touches Settings.shared or UsageHistory.shared.
    static func configure(arguments: [String]) throws {
        guard let path = flagValue(arguments, "--fixture") else { return }
        let data = try Data(contentsOf: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        let fx = try JSONDecoder().decode(Fixture.self, from: data)
        guard let now = parseISO(fx.now) else { throw ConfigError(description: "fixture `now` isn't ISO 8601: \(fx.now)") }
        Clock.pinned = now
        UsageHistory.persist = false
        fixture = fx
        snapshotDest = flagValue(arguments, "--snapshot-all").map { ($0 as NSString).expandingTildeInPath }
        UsageHistory.shared.replaceSamples(fx.history.map {
            HistorySample(timestamp: now.addingTimeInterval(-$0.ago), utilization: $0.u)
        })
    }
}
