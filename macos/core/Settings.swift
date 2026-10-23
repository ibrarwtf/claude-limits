import Foundation

enum TokenSource: Int { case auto = 0, file = 1, shell = 2 }

final class Settings {
    static let shared = Settings()
    /// Fixture mode gets an empty throwaway domain, so snapshots show default
    /// toggles and never write into the user's real settings.
    private let d: UserDefaults = {
        guard FixtureMode.isActive else { return .standard }
        let name = "claude-limits.fixture"
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        return s
    }()

    var tokenSource: TokenSource {
        get { TokenSource(rawValue: d.integer(forKey: "tokenSourceMode")) ?? .auto }
        set { d.set(newValue.rawValue, forKey: "tokenSourceMode") }
    }
    var customFilePath: String {
        get { d.string(forKey: "customFilePath") ?? "" }
        set { d.set(newValue, forKey: "customFilePath") }
    }
    var customShellCommand: String {
        get { d.string(forKey: "customShellCommand") ?? "" }
        set { d.set(newValue, forKey: "customShellCommand") }
    }
    /// Persisted across app restarts — prevents rapid relaunches from bursting the rate limit.
    var lastSuccessfulPoll: Date? {
        get { d.object(forKey: "lastSuccessfulPoll") as? Date }
        set { d.set(newValue, forKey: "lastSuccessfulPoll") }
    }
    /// Persisted "do not poll until" — honours Anthropic's Retry-After across launches.
    var nextAllowedPoll: Date? {
        get { d.object(forKey: "nextAllowedPoll") as? Date }
        set { d.set(newValue, forKey: "nextAllowedPoll") }
    }
    /// JSON-encoded last successful UsageResponse so the menu bar shows
    /// real data immediately on launch instead of "—".
    var lastResponseJSON: Data? {
        get { d.data(forKey: "lastResponseJSON") }
        set { d.set(newValue, forKey: "lastResponseJSON") }
    }
    /// Count of consecutive rate-limit responses. Persisted across launches so
    /// install.sh churn doesn't reset the exponential back-off counter.
    var consecutiveRateLimits: Int {
        get { d.integer(forKey: "consecutiveRateLimits") }
        set { d.set(newValue, forKey: "consecutiveRateLimits") }
    }

    /// Thresholds (e.g. 80, 95) already notified in the current 5h window.
    /// Reset when `lastNotifiedResetsAt` no longer matches the live `resets_at`.
    var notifiedThresholds: Set<Int> {
        get {
            let arr = d.array(forKey: "notifiedThresholds") as? [Int] ?? []
            return Set(arr)
        }
        set { d.set(Array(newValue), forKey: "notifiedThresholds") }
    }
    /// `resets_at` string the threshold set was recorded against. When this
    /// changes the live window has rolled over and the set should clear.
    var lastNotifiedResetsAt: String? {
        get { d.string(forKey: "lastNotifiedResetsAt") }
        set { d.set(newValue, forKey: "lastNotifiedResetsAt") }
    }

    // Sub-toggles — stored as inverse "hide" flags so the unset/zero default
    // reads as "show everything" (matches new-install expectations).
    var showPercentage: Bool {
        get { !d.bool(forKey: "hidePercentage") }
        set { d.set(!newValue, forKey: "hidePercentage") }
    }
    var showWave: Bool {
        get { !d.bool(forKey: "hideWave") }
        set { d.set(!newValue, forKey: "hideWave") }
    }
    var showResetTime: Bool {
        get { !d.bool(forKey: "hideResetTime") }
        set { d.set(!newValue, forKey: "hideResetTime") }
    }

    /// Gates the auto-open-Settings logic so it fires once for new installs only.
    var didFirstLaunch: Bool {
        get { d.bool(forKey: "didFirstLaunch") }
        set { d.set(newValue, forKey: "didFirstLaunch") }
    }

    /// Reflects whether the LaunchAgent plist exists in ~/Library/LaunchAgents/.
    /// The setter toggles its presence; the running app stays alive either way
    /// (we don't bootout the agent because that would terminate ourselves).
    private static let launchAgentLabel = "claude-limits"
    private var launchAgentPlistPath: String {
        ("~/Library/LaunchAgents/\(Settings.launchAgentLabel).plist" as NSString).expandingTildeInPath
    }
    var launchAtStartup: Bool {
        get {
            FileManager.default.fileExists(atPath: launchAgentPlistPath)
        }
        set {
            if newValue {
                if !FileManager.default.fileExists(atPath: launchAgentPlistPath) {
                    let appBin = Bundle.main.bundlePath + "/Contents/MacOS/claude-limits"
                    let plist = """
                    <?xml version="1.0" encoding="UTF-8"?>
                    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                    <plist version="1.0">
                    <dict>
                        <key>Label</key><string>\(Settings.launchAgentLabel)</string>
                        <key>ProgramArguments</key>
                        <array><string>\(appBin)</string></array>
                        <key>RunAtLoad</key><true/>
                        <key>KeepAlive</key>
                        <dict>
                            <key>SuccessfulExit</key><false/>
                            <key>Crashed</key><true/>
                        </dict>
                        <key>ProcessType</key><string>Interactive</string>
                        <key>StandardOutPath</key><string>/tmp/claude-limits.log</string>
                        <key>StandardErrorPath</key><string>/tmp/claude-limits.log</string>
                    </dict>
                    </plist>
                    """
                    try? plist.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
                }
            } else {
                try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
            }
        }
    }
}
