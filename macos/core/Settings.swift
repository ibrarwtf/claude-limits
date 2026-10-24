import Foundation

/// UserDefaults wrapper; the stored keys are declared in logic/core.pl.
final class Settings {
    static let shared = Settings()
    /// Fixture mode gets an empty throwaway domain, so snapshots show default
    /// toggles and never write into the user's real settings.
    let d: UserDefaults = {
        guard FixtureMode.isActive else { return .standard }
        let name = "claude-limits.fixture"
        let s = UserDefaults(suiteName: name)!
        s.removePersistentDomain(forName: name)
        return s
    }()

    // Stored settings are generated from logic/core.pl (extension Settings
    // in Logic.swift); only launch-at-login lives here.

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
