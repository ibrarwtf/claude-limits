import AppKit
import Foundation

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - API models
// ──────────────────────────────────────────────────────────────────────────────

struct UsageBucket: Codable {
    let utilization: Double
    let resetsAt: String?
    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ExtraUsage: Codable {
    let isEnabled: Bool?
    let monthlyLimit: Double?
    let usedCredits: Double?
    let utilization: Double?
    let currency: String?
    enum CodingKeys: String, CodingKey {
        case isEnabled = "is_enabled"
        case monthlyLimit = "monthly_limit"
        case usedCredits = "used_credits"
        case utilization
        case currency
    }
}

struct UsageResponse: Codable {
    let fiveHour: UsageBucket?
    let sevenDay: UsageBucket?
    let sevenDayOauthApps: UsageBucket?
    let sevenDayOpus: UsageBucket?
    let sevenDaySonnet: UsageBucket?
    let sevenDayCowork: UsageBucket?
    let sevenDayOmelette: UsageBucket?
    let extraUsage: ExtraUsage?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case sevenDayOmelette = "seven_day_omelette"
        case extraUsage = "extra_usage"
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Errors (with friendly rendering)
// ──────────────────────────────────────────────────────────────────────────────

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

    /// Single-line friendly explanation for the dropdown.
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
            return "Your Claude token is invalid or expired. Sign in to Claude to refresh it."
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

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - History (sparkline source)
// ──────────────────────────────────────────────────────────────────────────────

struct HistorySample: Codable {
    let timestamp: Date
    let utilization: Double
}

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

    /// Record a failed poll. Stored as utilization = -1 sentinel so rendering
    /// can either treat it as a baseline gap or paint a notch below 0.
    /// Sparkline rendering ignores these (clamps to ▁).
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

    /// Bars represent *burn rate* between consecutive samples (percentage
    /// points consumed since the last poll), not absolute utilization.
    /// Scaling: 0..3pp/sample → ▁..█; spikes above 3pp clamp to █.
    func sparkline(width: Int = 10) -> String {
        let bars = ["▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        // Need width+1 samples to compute width deltas.
        let recent = Array(samples.suffix(width + 1))
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

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Settings (UserDefaults-backed)
// ──────────────────────────────────────────────────────────────────────────────

enum TokenSource: Int { case auto = 0, file = 1, shell = 2 }

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard

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
    var pollIntervalSeconds: Double {
        get { let v = d.double(forKey: "pollIntervalSeconds"); return v >= 30 ? v : 120.0 }
        set { d.set(max(30.0, newValue), forKey: "pollIntervalSeconds") }
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
    /// Count of consecutive rate-limit responses. Used for exponential back-off.
    /// Persisted across launches so install.sh churn doesn't reset the count.
    var consecutiveRateLimits: Int {
        get { d.integer(forKey: "consecutiveRateLimits") }
        set { d.set(newValue, forKey: "consecutiveRateLimits") }
    }

    // ── Menu-bar visibility (master + 3 sub-toggles) ───────────────────
    // Stored as inverse "hide" flags so the unset/zero default reads as
    // "show everything" — matches new-install expectations.
    var menubarEnabled: Bool {
        get { !d.bool(forKey: "menubarHidden") }
        set { d.set(!newValue, forKey: "menubarHidden") }
    }
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

    /// Set to true after the very first launch completes. Used to gate the
    /// auto-open Settings window so it only fires once for new installs,
    /// not on every login.
    var didFirstLaunch: Bool {
        get { d.bool(forKey: "didFirstLaunch") }
        set { d.set(newValue, forKey: "didFirstLaunch") }
    }

    /// Reflects whether the LaunchAgent plist exists in
    /// ~/Library/LaunchAgents/. Setting toggles its presence; running app
    /// stays alive either way (we don't bootout the agent because that
    /// would terminate ourselves).
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

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Token loading
// ──────────────────────────────────────────────────────────────────────────────

let knownCredentialPaths: [String] = [
    "~/.claude/.credentials.json",
    "~/Library/Application Support/Claude/claude-code/.credentials.json",
    "~/Library/Application Support/Claude/.credentials.json",
]

let shellCommandExample = "ssh devbox 'cat ~/.claude/.credentials.json'"

func extractTokenFromText(_ text: String) -> String? {
    if let data = text.data(using: .utf8),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        if let oauth = obj["claudeAiOauth"] as? [String: Any],
           let tok = oauth["accessToken"] as? String, !tok.isEmpty { return tok }
        if let tok = obj["accessToken"] as? String, !tok.isEmpty { return tok }
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmed.isEmpty && !trimmed.contains(" ") && !trimmed.contains("\n") && trimmed.hasPrefix("sk-") {
        return trimmed
    }
    return nil
}

func loadTokenFromFile(_ rawPath: String) throws -> String {
    let path = (rawPath as NSString).expandingTildeInPath
    guard FileManager.default.fileExists(atPath: path) else {
        throw AppError.tokenNotFound
    }
    let text = try String(contentsOfFile: path, encoding: .utf8)
    if let tok = extractTokenFromText(text) { return tok }
    throw AppError.parseFailed("no accessToken in \(path)")
}

func runShell(_ cmd: String, timeout: TimeInterval = 10.0) throws -> String {
    let task = Process()
    task.launchPath = "/bin/zsh"
    task.arguments = ["-l", "-c", cmd]
    let outPipe = Pipe(); let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    try task.run()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { task.waitUntilExit(); group.leave() }
    if group.wait(timeout: .now() + timeout) == .timedOut {
        task.terminate()
        throw AppError.commandFailed("timed out after \(Int(timeout))s")
    }
    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw AppError.commandFailed("exit \(task.terminationStatus): \(err.prefix(200))")
    }
    return out
}

func loadTokenFromShell(_ cmd: String) throws -> String {
    if cmd.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AppError.tokenNotFound
    }
    let output = try runShell(cmd)
    if let tok = extractTokenFromText(output) { return tok }
    throw AppError.parseFailed("shell command output didn't contain a token")
}

func loadAccessToken() throws -> String {
    switch Settings.shared.tokenSource {
    case .auto:
        for path in knownCredentialPaths {
            if let tok = try? loadTokenFromFile(path) { return tok }
        }
        throw AppError.tokenNotFound
    case .file:
        let path = Settings.shared.customFilePath
        if path.isEmpty { throw AppError.tokenNotFound }
        return try loadTokenFromFile(path)
    case .shell:
        return try loadTokenFromShell(Settings.shared.customShellCommand)
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - API client
// ──────────────────────────────────────────────────────────────────────────────

let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
let oauthBeta = "oauth-2025-04-20"

func fetchUsage(taskHandle: ((URLSessionDataTask) -> Void)? = nil,
                completion: @escaping (Result<UsageResponse, AppError>) -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let token: String
        do { token = try loadAccessToken() }
        catch let e as AppError { completion(.failure(e)); return }
        catch { completion(.failure(.parseFailed(error.localizedDescription))); return }

        var req = URLRequest(url: usageURL)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(oauthBeta, forHTTPHeaderField: "anthropic-beta")
        req.timeoutInterval = 10

        let task = URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err {
                let code = (err as NSError).code
                if code == NSURLErrorCancelled { return } // user-cancelled, swallow
                if code == NSURLErrorTimedOut { completion(.failure(.requestTimeout)); return }
                if code == NSURLErrorNotConnectedToInternet
                    || code == NSURLErrorCannotFindHost
                    || code == NSURLErrorCannotConnectToHost
                    || code == NSURLErrorNetworkConnectionLost {
                    completion(.failure(.networkUnavailable)); return
                }
                completion(.failure(.parseFailed(err.localizedDescription))); return
            }
            let body = String(data: data ?? Data(), encoding: .utf8) ?? ""
            if let http = resp as? HTTPURLResponse {
                switch http.statusCode {
                case 200: break
                case 401: completion(.failure(.authFailed)); return
                case 403: completion(.failure(.forbidden)); return
                case 429:
                    var retry: TimeInterval? = nil
                    if let s = (http.allHeaderFields["Retry-After"] as? String) ?? (http.allHeaderFields["retry-after"] as? String),
                       let n = Double(s.trimmingCharacters(in: .whitespaces)) {
                        retry = n
                    }
                    completion(.failure(.rateLimited(retryAfter: retry))); return
                default:
                    completion(.failure(.httpError(http.statusCode, String(body.prefix(200))))); return
                }
            }
            guard let data = data else {
                completion(.failure(.parseFailed("empty response"))); return
            }
            do {
                let u = try JSONDecoder().decode(UsageResponse.self, from: data)
                completion(.success(u))
            } catch {
                completion(.failure(.parseFailed(error.localizedDescription)))
            }
        }
        DispatchQueue.main.async { taskHandle?(task) }
        task.resume()
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Helpers
// ──────────────────────────────────────────────────────────────────────────────

func parseISO(_ s: String?) -> Date? {
    guard let s = s else { return nil }
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}

/// Format the time-remaining string for the menu-bar widget.
/// Returns nil when there's no active 5-hour window (Anthropic only sends
/// resets_at once you've made a request inside a window). Callers should
/// treat nil as "drop this piece" rather than rendering a placeholder —
/// faking a countdown when there's none is misleading.
func formatTimeRemaining(_ resetsAt: String?) -> String? {
    guard let d = parseISO(resetsAt) else { return nil }
    let total = max(0, Int(d.timeIntervalSinceNow))
    let h = total / 3600, m = (total % 3600) / 60
    return h > 0 ? "\(h):\(String(format: "%02d", m))" : "\(m)m"
}

func progressBar(_ pct: Double, width: Int = 18) -> String {
    let p = max(0, min(100, pct))
    let filled = Int(round(Double(width) * p / 100.0))
    return String(repeating: "■", count: filled) + String(repeating: "□", count: width - filled)
}

/// Format the rate-limit countdown for the dropdown row.
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

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - App delegate
// ──────────────────────────────────────────────────────────────────────────────

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var animationTimer: Timer?
    var animationFrame = 0
    var animationStartedAt: Date?
    // One full bounce of the wave palindrome is 18 frames @ 12 fps = 1.5 s.
    // The animation must run at least that long for the bounce to be visible.
    let minAnimationDuration: TimeInterval = 1.5
    var isRefreshing = false
    var currentTask: URLSessionDataTask?
    var currentRequestToken: UUID?
    var lastResponse: UsageResponse?
    var lastUpdated: Date?
    var lastError: AppError?
    var settingsWindow: NSWindow?
    var tickTimer: Timer?

    // Error animation cycle (cold-start only — runs only when there's no
    // prior successful data to fall back on). Monotonic 12 fps counter;
    // cyclePos = frame mod errorCycleFrames picks the phase for this tick.
    var rateLimitCycleTimer: Timer?
    var rateLimitAnimFrame: Int = 0

    // Live "Last updated: Xs ago" line — refreshed once per second while the
    // dropdown is open so the counter visibly ticks up.
    weak var lastUpdatedMenuItem: NSMenuItem?
    weak var resetMenuItem: NSMenuItem?
    var menuTickTimer: Timer?
    /// When the next pollTimer tick will fire — used for "next in Xs" display.
    var nextPollAt: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        // Auto-size the slot to its content. Errors with prior data don't
        // trigger the marquee anymore, so the marquee only runs at cold-start
        // (rare) — accepting the minor resize there beats wasting space in the
        // 99% case.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "claude-limits"
        statusItem.isVisible = true
        statusItem.button?.title = "—"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Restore the last successful response from disk so we render real
        // data immediately, even before the first poll completes.
        if let data = Settings.shared.lastResponseJSON,
           let r = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            self.lastResponse = r
            self.lastUpdated = Settings.shared.lastSuccessfulPoll
            updateTitle()
        }

        // If we're still inside a rate-limit window from the previous process,
        // record the error state — but only run the marquee cycle when we have
        // no prior data to fall back on. With prior data, the menu bar stays
        // passive (showing the last known state) and the error surfaces only
        // in the dropdown.
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            self.lastError = .rateLimited(retryAfter: until.timeIntervalSinceNow)
            if self.lastResponse == nil {
                startRateLimitCycle()
            }
        }

        // First poll respects rate-limit suspension and last-successful-poll across launches.
        if shouldPollNow() {
            triggerRefresh(animated: true)
        } else {
            updateTitle()
        }
        schedulePoll()

        // Tick the title every 30s to update the reset countdown without a fetch.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateTitle()
        }

        // Open the Settings window only on the very first launch (new install).
        // Subsequent logins keep the menu-bar widget silent.
        if !Settings.shared.didFirstLaunch {
            Settings.shared.didFirstLaunch = true
            // Auto-enable autostart on first launch so brew-installed users
            // get a working LaunchAgent without having to flip a setting.
            // The setter writes ~/Library/LaunchAgents/<bundle>.plist; the
            // agent loads on the next login. Idempotent — does nothing if
            // the user installed via scripts/install.sh (file already exists).
            Settings.shared.launchAtStartup = true
            // Async so AppKit's launch dance is done before we order a window
            // front (LSUIElement apps otherwise create the window without
            // making it visible).
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
    }

    /// Returns true if we may issue a fetch right now.
    /// Rate-limit suspension and a per-launch debounce protect Anthropic's API.
    func shouldPollNow() -> Bool {
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            return false
        }
        if let last = Settings.shared.lastSuccessfulPoll {
            let interval = Settings.shared.pollIntervalSeconds
            // Don't burst on relaunch — wait at least half a poll interval since the
            // most recent successful fetch (which may have been a previous process).
            if Date().timeIntervalSince(last) < interval / 2 {
                return false
            }
        }
        return true
    }

    func schedulePoll() {
        pollTimer?.invalidate()
        let interval = Settings.shared.pollIntervalSeconds
        nextPollAt = Date().addingTimeInterval(interval)
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.nextPollAt = Date().addingTimeInterval(Settings.shared.pollIntervalSeconds)
            if self.shouldPollNow() { self.triggerRefresh(animated: false) }
            else { self.updateTitle() }
        }
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showDropdown()
        } else {
            // Manual click: always show wave animation as click-acknowledgement.
            // If we're rate-limited, play the wave briefly but don't actually
            // fetch — burning a request now would only extend the suspension.
            if let until = Settings.shared.nextAllowedPoll, until > Date() {
                lastError = .rateLimited(retryAfter: until.timeIntervalSinceNow)
                startAnimation()
                // 1.5 s = one full bounce of the wave palindrome.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    self?.stopAnimation()
                }
                return
            }
            triggerRefresh(animated: true, force: true)
        }
    }

    func showDropdown() {
        let menu = NSMenu()
        menu.delegate = self
        buildMenu(into: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Schedule on .common mode so the timer keeps firing while the menu
        // is open (the menu tracking runloop mode would otherwise pause it).
        menuTickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickMenuLastUpdated()
        }
        RunLoop.current.add(timer, forMode: .common)
        menuTickTimer = timer
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        menuTickTimer?.invalidate()
        menuTickTimer = nil
        lastUpdatedMenuItem = nil
        resetMenuItem = nil
    }

    func tickMenuLastUpdated() {
        if let item = lastUpdatedMenuItem {
            let s = formatTopStatusLine()
            item.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        if let item = resetMenuItem, let r = lastResponse, let f = r.fiveHour {
            let s = formatResetLine(f)
            item.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.labelColor])
        }
    }

    // ── Title rendering ──────────────────────────────────────────────────────

    func updateTitle() {
        if isRefreshing || animationTimer != nil { return } // animation owns the title
        if rateLimitCycleTimer != nil { return }            // rate-limit cycle owns it

        // Master toggle: when off, hide the status item entirely. To get
        // back into Settings, the user can re-open the .app from Finder /
        // Spotlight — applicationShouldHandleReopen catches that and shows
        // Settings.
        if !Settings.shared.menubarEnabled {
            statusItem.isVisible = false
            return
        }
        statusItem.isVisible = true

        if let err = lastError, lastResponse == nil {
            // Pure-error state: no prior successful response. Show only the error.
            statusItem.button?.title = err.titleSymbol
            return
        }
        if let r = lastResponse, let f = r.fiveHour {
            let pct = Int(round(f.utilization))
            let spark = UsageHistory.shared.sparkline(width: 10)
            let resetStr = formatTimeRemaining(f.resetsAt)
            let menuBarSize = NSFont.systemFontSize
            let normalFont = NSFont.menuBarFont(ofSize: menuBarSize)
            let sparkFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            let normalAttrs: [NSAttributedString.Key: Any] = [.font: normalFont]
            let sparkAttrs: [NSAttributedString.Key: Any] = [
                .font: sparkFont,
                .baselineOffset: 1.0,
            ]
            let title = NSMutableAttributedString()
            // Append each sub-part with a leading space when something came before.
            let s = Settings.shared
            var prevAdded = false
            if s.showPercentage {
                title.append(NSAttributedString(string: "\(pct)%", attributes: normalAttrs))
                prevAdded = true
            }
            if s.showWave {
                if prevAdded { title.append(NSAttributedString(string: " ", attributes: normalAttrs)) }
                title.append(NSAttributedString(string: spark, attributes: sparkAttrs))
                prevAdded = true
            }
            // resetStr is nil when there's no active 5-hour window
            // (Anthropic returns no resets_at until the user makes a
            // request). In that state we drop the piece entirely rather
            // than rendering a fake countdown.
            if s.showResetTime, let resetStr = resetStr {
                if prevAdded { title.append(NSAttributedString(string: " ", attributes: normalAttrs)) }
                title.append(NSAttributedString(string: resetStr, attributes: normalAttrs))
                prevAdded = true
            }
            // If somehow all sub-toggles ended up off but master is on,
            // fall back to a single dot so the widget isn't a zero-width sliver.
            // (UI keeps master and sub toggles consistent — this is defensive.)
            if !prevAdded {
                statusItem.button?.title = "·"
                return
            }
            statusItem.button?.attributedTitle = title
        } else {
            statusItem.button?.title = "—"
        }
    }

    /// User clicked the .app from Finder/Spotlight while the app is already
    /// running (which is the only way to get back into Settings if they hid
    /// the menu-bar widget via the master toggle).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // ── Refresh + animation ──────────────────────────────────────────────────

    func triggerRefresh(animated: Bool, force: Bool = false) {
        if isRefreshing && !force { return }
        if force, let t = currentTask { t.cancel() }
        isRefreshing = true
        if animated { startAnimation() }
        // Manual refreshes (force=true: click-driven or post-Save) push the
        // periodic timer's next-fire forward by a full interval so we don't
        // double-poll Anthropic right after a manual click and wake their
        // rate-limiter for nothing.
        if force { schedulePoll() }
        let myToken = UUID()
        currentRequestToken = myToken
        fetchUsage(taskHandle: { [weak self] task in
            self?.currentTask = task
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.currentRequestToken != myToken { return } // stale, dropped
                self.isRefreshing = false
                self.scheduleAnimationStop()
                switch result {
                case .success(let r):
                    self.lastResponse = r
                    self.lastUpdated = Date()
                    self.lastError = nil
                    Settings.shared.lastSuccessfulPoll = Date()
                    Settings.shared.nextAllowedPoll = nil
                    Settings.shared.consecutiveRateLimits = 0
                    Settings.shared.lastResponseJSON = try? JSONEncoder().encode(r)
                    self.stopRateLimitCycle()
                    if let f = r.fiveHour {
                        UsageHistory.shared.append(utilization: f.utilization, resetsAt: f.resetsAt)
                    }
                case .failure(let e):
                    self.lastError = e
                    // Record the failed poll so the top-wave shows real
                    // gaps where errors occurred rather than a smooth line.
                    UsageHistory.shared.appendError()
                    if case .rateLimited(let retry) = e {
                        // Exponential back-off on consecutive 429s.
                        // 1st: 5min, 2nd: 10min, 3rd: 20min, 4th+: capped at 30min.
                        // Anthropic cooldowns can be longer than our retry interval,
                        // so retrying too eagerly just resets their counter.
                        Settings.shared.consecutiveRateLimits += 1
                        let count = Settings.shared.consecutiveRateLimits
                        let exp = min(300.0 * pow(2.0, Double(count - 1)), 1800.0)
                        // Honour the server's Retry-After if it asked for longer.
                        let secs = max(retry ?? 0, exp)
                        let until = Date().addingTimeInterval(secs)
                        Settings.shared.nextAllowedPoll = until
                        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                        NSLog("claude-limits rate limited (#\(count)) — next attempt at \(f.string(from: until)) (waiting \(Int(secs))s)")
                    } else {
                        NSLog("claude-limits fetch error: \(e.friendlyMessage)")
                    }
                    // Only run the marquee when we have no prior data to fall
                    // back on. If a previous poll succeeded, we just keep
                    // showing that data unchanged — the error surfaces in the
                    // dropdown but doesn't disturb the menu-bar widget.
                    if self.lastResponse == nil {
                        self.startRateLimitCycle()
                    } else {
                        self.stopRateLimitCycle()
                    }
                }
                self.updateTitle()
            }
        }
    }

    /// Bouncing-peak palindrome animation, 12 fps, while a refresh is in flight.
    func startAnimation() {
        animationTimer?.invalidate()
        animationFrame = 0
        animationStartedAt = Date()

        let menuBarSize = NSFont.systemFontSize
        let sparkFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let normalFont = NSFont.menuBarFont(ofSize: menuBarSize)
        let sparkAttrs: [NSAttributedString.Key: Any] = [
            .font: sparkFont,
            .baselineOffset: 1.0,
        ]
        // Reuse the bouncing-peak wave frames + palindrome from the error
        // animation cycle so both refresh and error waves read the same way.
        let frames = AppDelegate.errorWaveFrames.map { Array($0) }
        let indices = AppDelegate.errorWavePalindrome

        let normalAttrs: [NSAttributedString.Key: Any] = [.font: normalFont]
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Master off: don't disturb the hidden status item.
            if !Settings.shared.menubarEnabled { return }
            let step = self.animationFrame % indices.count
            let frame = frames[indices[step]]
            // Slot-machine reels: % and reset spin while bars dance.
            // Each piece is gated by its own visibility toggle so a hidden
            // part stays hidden during the click-acknowledgement animation.
            let pct = Int.random(in: 0..<100)
            let h = Int.random(in: 0...9), m = Int.random(in: 0..<60)
            let resetStr = "\(h):\(String(format: "%02d", m))"
            let title = NSMutableAttributedString()
            let s = Settings.shared
            var prev = false
            if s.showPercentage {
                title.append(NSAttributedString(string: "\(pct)%", attributes: normalAttrs))
                prev = true
            }
            if s.showWave {
                if prev { title.append(NSAttributedString(string: " ", attributes: normalAttrs)) }
                title.append(NSAttributedString(string: String(frame), attributes: sparkAttrs))
                prev = true
            }
            if s.showResetTime {
                if prev { title.append(NSAttributedString(string: " ", attributes: normalAttrs)) }
                title.append(NSAttributedString(string: resetStr, attributes: normalAttrs))
                prev = true
            }
            // If everything's off but master is on, fall back to a single dot
            // so the click target doesn't collapse to zero width mid-animation.
            if !prev {
                self.statusItem.button?.title = "·"
                self.statusItem.button?.attributedTitle = NSAttributedString(string: "")
            } else {
                self.statusItem.button?.attributedTitle = title
            }
            self.animationFrame += 1
        }
    }

    func scheduleAnimationStop() {
        let elapsed = animationStartedAt.map { Date().timeIntervalSince($0) } ?? minAnimationDuration
        let remaining = max(0, minAnimationDuration - elapsed)
        if remaining <= 0 { stopAnimation() }
        else {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.stopAnimation()
            }
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStartedAt = nil
        updateTitle()
    }

    // ── Error animation cycle ───────────────────────────────────────────────
    // Two-phase cycle: Phase A bouncing wave (~1.5s), Phase B marquee scroll
    // of friendly message (~5s). Both render mono in a fixed 22-char window
    // so the widget keeps the same width throughout.

    func startRateLimitCycle() {
        rateLimitCycleTimer?.invalidate()
        rateLimitAnimFrame = 0
        rateLimitCycleTimer = Timer.scheduledTimer(withTimeInterval: 1.0/12.0, repeats: true) { [weak self] _ in
            self?.tickRateLimitCycle()
        }
    }

    func stopRateLimitCycle() {
        rateLimitCycleTimer?.invalidate()
        rateLimitCycleTimer = nil
    }

    // Wave frames: a single peak (█) moves from index 0 to 9 with symmetric
    // falloff. Palindrome flips this so the peak visibly bounces off the
    // right wall and returns to the left, instead of jumping back.
    static let errorWaveFrames: [String] = [
        "█▇▆▅▄▃▂▁▁▁",  // peak at 0
        "▇█▇▆▅▄▃▂▁▁",  // peak at 1
        "▆▇█▇▆▅▄▃▂▁",  // peak at 2
        "▅▆▇█▇▆▅▄▃▂",  // peak at 3
        "▄▅▆▇█▇▆▅▄▃",  // peak at 4
        "▃▄▅▆▇█▇▆▅▄",  // peak at 5
        "▂▃▄▅▆▇█▇▆▅",  // peak at 6
        "▁▂▃▄▅▆▇█▇▆",  // peak at 7
        "▁▁▂▃▄▅▆▇█▇",  // peak at 8
        "▁▁▁▂▃▄▅▆▇█",  // peak at 9 (right edge)
    ]
    static let errorWavePalindrome: [Int] = {
        var ix: [Int] = []
        for i in 0..<errorWaveFrames.count { ix.append(i) }
        for i in stride(from: errorWaveFrames.count - 2, through: 1, by: -1) { ix.append(i) }
        return ix
    }()
    static let errorPhaseAFrames = errorWavePalindrome.count   // 18 — ~1.5 s @ 12 fps, one clean bounce
    static let errorPhaseBFrames = 60                          // ~5.0 s marquee at 12 fps
    static let errorCycleFrames  = errorPhaseAFrames + errorPhaseBFrames
    /// Cap the cold-start error animation at this many full cycles before
    /// settling on the static error symbol. Prevents the menu bar from
    /// twitching forever when the user can't (or won't) fix the error.
    /// 3 × ~6.5 s = ~19.5 s of animation, then quiet.
    static let errorMaxCycles = 3

    func tickRateLimitCycle() {
        // Master off: keep showing the static template icon, no animation.
        if !Settings.shared.menubarEnabled { return }
        if lastError == nil {
            stopRateLimitCycle()
            updateTitle()
            return
        }
        // Bail when rate-limit suspension expires so the next poll can run.
        if case .rateLimited = lastError ?? .parseFailed(""),
           let until = Settings.shared.nextAllowedPoll,
           until <= Date() {
            stopRateLimitCycle()
            updateTitle()
            return
        }
        // Cap: after errorMaxCycles full cycles, stop animating and let
        // updateTitle() render the static err.titleSymbol fallback. The
        // animation will start again on the next fresh error (because
        // startRateLimitCycle resets rateLimitAnimFrame to 0).
        if rateLimitAnimFrame >= AppDelegate.errorMaxCycles * AppDelegate.errorCycleFrames {
            stopRateLimitCycle()
            updateTitle()
            return
        }

        let cyclePos = rateLimitAnimFrame % AppDelegate.errorCycleFrames
        let mono = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize - 1, weight: .regular)

        if cyclePos < AppDelegate.errorPhaseAFrames {
            // Phase A: dim placeholders flanking an animated wave palindrome.
            // Layout: "--  <10-char wave>   --:--" (22 chars total, mono).
            let palIdx = AppDelegate.errorWavePalindrome[
                cyclePos % AppDelegate.errorWavePalindrome.count]
            let wave = AppDelegate.errorWaveFrames[palIdx]
            let title = NSMutableAttributedString()
            let dim: [NSAttributedString.Key: Any] = [
                .font: mono, .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let bright: [NSAttributedString.Key: Any] = [
                .font: mono, .foregroundColor: NSColor.labelColor,
            ]
            title.append(NSAttributedString(string: "--  ",     attributes: dim))
            title.append(NSAttributedString(string: wave,       attributes: bright))
            title.append(NSAttributedString(string: "   --:--", attributes: dim))
            statusItem.button?.attributedTitle = title
        } else {
            // Phase B: marquee scroll of friendly message in 22-char window.
            // ~1.17 chars/frame at 12 fps → ~14 chars/sec.
            let phaseFrame = cyclePos - AppDelegate.errorPhaseAFrames
            let core = rateLimitTypewriterText() + "    "
            let windowWidth = 22
            let cycleText = String(repeating: " ", count: windowWidth) + core
            let chars = Array(cycleText)
            let charPos = Int(Double(phaseFrame) * 1.17) % chars.count
            var visible = ""
            for i in 0..<windowWidth {
                visible.append(chars[(charPos + i) % chars.count])
            }
            statusItem.button?.attributedTitle = NSAttributedString(
                string: visible,
                attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        }
        rateLimitAnimFrame += 1
    }

    /// Friendly per-error message rendered in the marquee phase.
    func rateLimitTypewriterText() -> String {
        guard let err = lastError else { return "—" }
        switch err {
        case .rateLimited:
            if let until = Settings.shared.nextAllowedPoll {
                let secs = max(0, Int(until.timeIntervalSinceNow))
                let m = secs / 60, s = secs % 60
                let when = m > 0 ? "\(m)m \(s)s" : "\(s)s"
                return "rate limit reached, retry in \(when)"
            }
            return "rate limit reached"
        case .authFailed:        return "token expired · sign in to claude"
        case .tokenNotFound:     return "token not configured · open settings"
        case .forbidden:         return "access forbidden · check account access"
        case .networkUnavailable: return "cannot reach api.anthropic.com"
        case .requestTimeout:    return "request timed out · trying again soon"
        case .commandFailed(let m): return "shell command failed: \(m.prefix(50))"
        case .parseFailed(let m):   return "parse error: \(m.prefix(50))"
        case .httpError(let c, _):  return "HTTP \(c) from anthropic"
        }
    }

    // ── Menu rendering ───────────────────────────────────────────────────────

    /// "Resets @ 3:10 PM · <state-dependent message>" — combines the reset
    /// clock time with a smoothed mileage estimate. Uses last 30 samples and
    /// a trimmed mean (drop top/bottom 20%) to flatten the bouncy projection
    /// caused by single-sample spikes.
    func formatResetLine(_ f: UsageBucket) -> String {
        // No active 5-hour window yet (Anthropic returns no resets_at
        // until you've made a request inside a window). Tell the user
        // exactly what's happening rather than guessing a clock time.
        guard let resetDate = parseISO(f.resetsAt) else {
            return "No active 5-hour window — starts on your next Claude request"
        }
        let df = DateFormatter()
        df.timeStyle = .short
        df.dateStyle = .none
        let resetClock = df.string(from: resetDate)

        // Wider window — last 30 samples (~60 min at 120s poll).
        let samples = Array(UsageHistory.shared.samples.suffix(30))
        if samples.count < 3 {
            return "Resets @ \(resetClock) · click to refresh"
        }
        // Non-negative deltas only (window resets dropped).
        var deltas: [Double] = []
        for i in 1..<samples.count {
            let d = samples[i].utilization - samples[i-1].utilization
            if d >= 0 { deltas.append(d) }
        }
        guard !deltas.isEmpty else {
            return "Resets @ \(resetClock)"
        }

        // Trimmed mean: sort, drop top/bottom 20%, average the middle 60%.
        // Robust to single-sample spikes.
        let sorted = deltas.sorted()
        let trim = max(1, sorted.count / 5)
        let middle: ArraySlice<Double>
        if sorted.count > 2 * trim {
            middle = sorted.dropFirst(trim).dropLast(trim)
        } else {
            middle = ArraySlice(sorted)
        }
        let avgPerMinute = middle.reduce(0, +) / Double(middle.count)
        let minutesToReset = max(0, resetDate.timeIntervalSinceNow / 60.0)
        let burnPpHr = avgPerMinute * 60.0

        if burnPpHr < 1 {
            return "Resets @ \(resetClock) · idle"
        }

        // Pace bucketing: compare actual burn against the rate that would
        // exactly hit 100% at reset (safePpHr). Below 0.7× = slow,
        // 0.7–1.1× = steady, above = fast.
        let pace: String
        if minutesToReset <= 0 {
            pace = "—"
        } else {
            let safePpHr = (100.0 - f.utilization) / minutesToReset * 60.0
            let mult = burnPpHr / safePpHr
            if mult < 0.7 { pace = "slow" }
            else if mult <= 1.1 { pace = "steady" }
            else { pace = "fast" }
        }

        let burnInt = Int(round(burnPpHr))
        var line = "Resets @ \(resetClock) · \(burnInt)%/h · \(pace)"

        // Append "100% in Yh Zm" only when the cap arrives before reset.
        let minsTo100 = (100.0 - f.utilization) / burnPpHr * 60.0
        if minsTo100 > 0 && minsTo100 < minutesToReset {
            let h = Int(minsTo100) / 60
            let m = Int(minsTo100) % 60
            line += h > 0 ? " · 100% in \(h)h \(m)m" : " · 100% in \(m)m"
        }
        return line
    }

    /// Single-line top status: "[error · ]Last updated: X · next in Y".
    func formatTopStatusLine() -> String {
        var prefix = ""
        if let err = lastError {
            if case .rateLimited = err {
                prefix = "rate-limited · "
            } else {
                prefix = "\(err.titleSymbol) · "
            }
        }
        let lastSeen = lastUpdated.map { liveRelativeTime($0) } ?? "never"
        let nextClause: String
        if case .rateLimited = lastError ?? .parseFailed(""),
           let np = Settings.shared.nextAllowedPoll {
            let secs = max(0, Int(np.timeIntervalSinceNow))
            nextClause = "next in \(formatNextAttempt(secs))"
        } else if lastUpdated == nil {
            nextClause = "click to refresh"
        } else if let np = nextPollAt {
            let secs = max(0, Int(np.timeIntervalSinceNow))
            if secs <= 0 { nextClause = "next now…" }
            else if secs < 60 { nextClause = "next in \(secs)s" }
            else {
                let m = secs / 60, s = secs % 60
                nextClause = "next in \(m)m \(s)s"
            }
        } else {
            nextClause = "—"
        }
        return "\(prefix)Last updated: \(lastSeen) · \(nextClause)"
    }

    func boldHeader(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: s,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        return item
    }

    func plainItem(_ s: String, dim: Bool = false, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        if let c = color {
            item.attributedTitle = NSAttributedString(string: s, attributes: [.foregroundColor: c])
        } else if dim {
            item.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        return item
    }

    func buildMenu(into menu: NSMenu) {
        // ── Top status line: [error · ]Last updated: X · next in Y ──────────
        let topLine = formatTopStatusLine()
        let topItem = NSMenuItem(title: topLine, action: nil, keyEquivalent: "")
        topItem.attributedTitle = NSAttributedString(
            string: topLine,
            attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        menu.addItem(topItem)
        lastUpdatedMenuItem = topItem

        // Quick action for actionable errors.
        if let err = lastError {
            if case .tokenNotFound = err { menu.addItem(openSettingsItem("Open Settings")) }
            if case .authFailed   = err { menu.addItem(openSettingsItem("Open Settings")) }
        }
        menu.addItem(.separator())

        // ── Resets @ HH:MM · burn · pace · 100% in (one line) ───────────────
        if let r = lastResponse, let f = r.fiveHour {
            let s = formatResetLine(f)
            let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
            item.attributedTitle = NSAttributedString(
                string: s,
                attributes: [.foregroundColor: NSColor.labelColor])
            menu.addItem(item)
            resetMenuItem = item
        }

        // ── Weekly limits — only render if there's at least one active bucket
        if let r = lastResponse {
            let weekly: [(String, UsageBucket?)] = [
                ("Overall", r.sevenDay),
                ("Opus", r.sevenDayOpus),
                ("Sonnet", r.sevenDaySonnet),
                ("OAuth apps", r.sevenDayOauthApps),
                ("Cowork", r.sevenDayCowork),
                ("Claude Design", r.sevenDayOmelette),
            ]
            let active = weekly.compactMap { (label, b) in b.map { (label, $0) } }
            if !active.isEmpty {
                menu.addItem(.separator())
                menu.addItem(boldHeader("Weekly limits"))
                for (label, bucket) in active {
                    let pct = Int(round(bucket.utilization))
                    menu.addItem(plainItem("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0))\(progressBar(bucket.utilization, width: 14))  \(pct)%"))
                }
            }
        }

        // ── Pay-as-you-go ────────────────────────────────────────────────────
        if let r = lastResponse, let extra = r.extraUsage, extra.isEnabled == true {
            menu.addItem(.separator())
            menu.addItem(boldHeader("Pay-as-you-go credits"))
            let used = extra.usedCredits ?? 0
            let limit = extra.monthlyLimit ?? 0
            let cur = extra.currency ?? "USD"
            menu.addItem(plainItem("  \(String(format: "%.2f", used)) / \(String(format: "%.2f", limit)) \(cur)", dim: true))
        }

        menu.addItem(.separator())

        // ── Actions ──────────────────────────────────────────────────────────
        let refresh = NSMenuItem(title: "Refresh now", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let openWeb = NSMenuItem(title: "Open claude.ai/settings/usage", action: #selector(openUsageWeb), keyEquivalent: "")
        openWeb.target = self
        menu.addItem(openWeb)
        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit claude-limits", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q"))
    }

    func openSettingsItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "  → \(title)", action: #selector(openSettings), keyEquivalent: "")
        item.target = self
        item.attributedTitle = NSAttributedString(
            string: "  → \(title)",
            attributes: [.foregroundColor: NSColor.labelColor])
        return item
    }

    @objc func refreshAction() {
        if let until = Settings.shared.nextAllowedPoll, until > Date() { return }
        triggerRefresh(animated: true, force: true)
    }

    @objc func openUsageWeb() {
        if let url = URL(string: "https://claude.ai/settings/usage") { NSWorkspace.shared.open(url) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindow.make(onSave: { [weak self] in
                self?.schedulePoll()
                self?.triggerRefresh(animated: true, force: true)
            })
        }
        // LSUIElement apps stay at .accessory permanently (no Dock icon).
        // makeKeyAndOrderFront alone doesn't reliably foreground the window
        // from menu-driven calls because the previous app keeps focus, so we
        // pair it with activate(ignoringOtherApps:) plus the window-level
        // escape hatch orderFrontRegardless(). Toggling activation policy to
        // .regular and back closes any window that became visible during it.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Settings window
// ──────────────────────────────────────────────────────────────────────────────

enum SettingsWindow {
    static func make(onSave: @escaping () -> Void) -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 660),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        win.title = "claude-limits — Settings"
        win.center()
        win.isReleasedWhenClosed = false
        let vc = SettingsViewController()
        vc.onSave = onSave
        win.contentViewController = vc
        return win
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - Top wave view
// Historic utilization plotted as a coral line with soft fill below. Real
// data only — leaves the strip empty when there's < 2 samples instead of
// faking a curve.
// ──────────────────────────────────────────────────────────────────────────────

final class TopWaveView: NSView {
    /// How many copies of the smoothed history to tile across the strip.
    /// Three repetitions visually echoes the rolling-window concept.
    private let tileCount = 3
    /// Light moving-average window for smoothing the raw samples.
    private let smoothWindow = 3

    override var isFlipped: Bool { false } // Cocoa-default Y-up

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        // Real data only — no synthesised fallback. Treat error sentinels
        // (utilization < 0) as 0 so they read as a flat dip in the line.
        let raw = UsageHistory.shared.samples.map {
            $0.utilization < 0 ? 0.0 : $0.utilization
        }
        guard raw.count >= 2 else {
            // Not enough history to plot anything yet — leave the strip
            // empty rather than fake a curve.
            return
        }
        let smoothed = movingAverage(raw, window: smoothWindow)
        // Tile the smoothed pattern N times across the strip. Each tile is
        // identical, which makes the rolling-window cadence visually obvious
        // even when the user only has one session of data.
        var samples: [Double] = []
        for _ in 0..<tileCount { samples.append(contentsOf: smoothed) }

        let padTop: CGFloat = 4, padBottom: CGFloat = 1
        let usable = bounds.height - padTop - padBottom
        let width = bounds.width
        let dx = width / CGFloat(samples.count - 1)

        var points: [NSPoint] = []
        for (i, v) in samples.enumerated() {
            let x = CGFloat(i) * dx
            let clamped = max(0.0, min(100.0, v))
            // Y-up: bigger value = higher pixel Y.
            let y = padBottom + (CGFloat(clamped) / 100.0) * usable
            points.append(NSPoint(x: x, y: y))
        }

        let isDark = self.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let lineColor = isDark
            ? NSColor(calibratedRed: 1.0, green: 0.667, blue: 0.533, alpha: 1.0)
            : NSColor(calibratedRed: 0.851, green: 0.467, blue: 0.333, alpha: 1.0)
        let fillTop = isDark
            ? NSColor(calibratedRed: 1.0, green: 0.667, blue: 0.533, alpha: 0.30)
            : NSColor(calibratedRed: 1.0, green: 0.6,   blue: 0.4,   alpha: 0.35)
        let fillBottom = NSColor(calibratedRed: fillTop.redComponent,
                                 green: fillTop.greenComponent,
                                 blue: fillTop.blueComponent,
                                 alpha: 0.0)

        // Filled area below the line.
        let fillPath = NSBezierPath()
        fillPath.move(to: NSPoint(x: 0, y: 0))
        fillPath.line(to: points[0])
        for p in points.dropFirst() { fillPath.line(to: p) }
        fillPath.line(to: NSPoint(x: width, y: 0))
        fillPath.close()
        if let grad = NSGradient(colors: [fillTop, fillBottom],
                                 atLocations: [1.0, 0.0],
                                 colorSpace: .sRGB) {
            grad.draw(in: fillPath, angle: 90)
        }

        // Stroked line on top.
        let linePath = NSBezierPath()
        linePath.lineWidth = 1.4
        linePath.lineJoinStyle = .round
        linePath.move(to: points[0])
        for p in points.dropFirst() { linePath.line(to: p) }
        lineColor.setStroke()
        linePath.stroke()
    }

    /// Centred moving-average smoothing. Each output value is the mean of
    /// the input value and (window/2) neighbours on each side, clamped at
    /// the array boundaries. Output length == input length.
    private func movingAverage(_ values: [Double], window: Int) -> [Double] {
        guard values.count > 1, window > 1 else { return values }
        let half = window / 2
        var out: [Double] = []
        out.reserveCapacity(values.count)
        for i in 0..<values.count {
            let lo = max(0, i - half)
            let hi = min(values.count - 1, i + half)
            let slice = values[lo...hi]
            out.append(slice.reduce(0, +) / Double(slice.count))
        }
        return out
    }
}

class SettingsViewController: NSViewController {
    var onSave: (() -> Void)?
    var modePopup: NSPopUpButton!
    var fileField: NSTextField!
    var shellField: NSTextField!
    var pollField: NSTextField!
    var statusLabel: NSTextField!
    var hintLabel: NSTextField!
    var fileRow: NSView!
    var shellRow: NSView!
    // Menu-bar visibility toggles
    var masterSwitch: NSSwitch!
    var pctSwitch: NSSwitch!
    var waveSwitch: NSSwitch!
    var resetSwitch: NSSwitch!
    var subTogglesStack: NSStackView!
    // Live preview mock of the menu-bar widget (next to the toggles).
    // Each label is shown/hidden as toggles flip.
    var mockContainer: NSView!
    var mockPct: NSTextField!
    var mockBars: NSTextField!
    var mockReset: NSTextField!
    // Other toggles
    var launchSwitch: NSSwitch!

    override func loadView() {
        let WIDTH: CGFloat = 720
        let HEIGHT: CGFloat = 660
        let container = NSView(frame: NSRect(x: 0, y: 0, width: WIDTH, height: HEIGHT))

        // ── Top wave (historic utilization plot) ────────────────────────────
        let wave = TopWaveView(frame: NSRect(x: 0, y: HEIGHT - 56, width: WIDTH, height: 56))
        wave.autoresizingMask = [.width, .minYMargin]
        container.addSubview(wave)

        // ── Section 1: Token source ─────────────────────────────────────────
        modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: [
            "Auto-detect (recommended)",
            "Custom file path",
            "Custom shell command",
        ])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)

        hintLabel = NSTextField(wrappingLabelWithString: "")
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        fileField = NSTextField()
        fileField.placeholderString = "~/.claude/.credentials.json"
        fileRow = makeFieldRow("File path", field: fileField)

        shellField = NSTextField()
        shellField.placeholderString = shellCommandExample
        shellRow = makeFieldRow("Shell command", field: shellField)

        pollField = NSTextField()
        pollField.placeholderString = "120"
        let pollRow = makeFieldRow("Poll interval (s)", field: pollField, fieldWidth: 80)

        let tokenRow = makeRow(
            "Token source",
            control: modePopup,
            info: "Where to read your Claude OAuth token. Auto-detect tries common paths; switch to file or shell-command if your token lives elsewhere.")

        let tokenControls = NSStackView(views: [tokenRow, hintLabel, fileRow, shellRow, pollRow])
        tokenControls.orientation = .vertical
        tokenControls.alignment = .leading
        tokenControls.spacing = 8
        let tokenSection = makeSection(iconView: makeKeyArt("credentials.json"),
                                       controls: tokenControls)

        // ── Section 2: Menu bar display ─────────────────────────────────────
        masterSwitch = makeSwitch()
        let masterRow = makeToggleRow("Show menu bar widget", sw: masterSwitch, bold: true,
            info: "Master switch. When off, hides the entire menu-bar widget. To get back into Settings, relaunch the app from Finder or Spotlight.")

        pctSwitch   = makeSwitch()
        waveSwitch  = makeSwitch()
        resetSwitch = makeSwitch()
        subTogglesStack = NSStackView(views: [
            makeToggleRow("Percentage", sw: pctSwitch,
                info: "The 5-hour quota usage as a percentage (e.g. \"23%\")."),
            makeToggleRow("Burn-rate wave", sw: waveSwitch,
                info: "Sparkline of recent burn rate. Each bar = one polling sample; newer bars on the right."),
            makeToggleRow("Reset countdown", sw: resetSwitch,
                info: "Hours and minutes until the current 5-hour window resets back to 0%."),
        ])
        subTogglesStack.orientation = .vertical
        subTogglesStack.alignment = .leading
        subTogglesStack.spacing = 4
        // No left inset on subs — visual hierarchy comes from font weight
        // (master is bold), so all switches align at the same x.

        let menuControls = NSStackView(views: [masterRow, subTogglesStack])
        menuControls.orientation = .vertical
        menuControls.alignment = .leading
        menuControls.spacing = 8
        let menuSection = makeSection(iconView: makeMenubarArt(), controls: menuControls)

        // ── Section 3: General ──────────────────────────────────────────────
        launchSwitch = makeSwitch()
        let launchRow = makeToggleRow("Open at login", sw: launchSwitch,
            info: "Start the app automatically when you log in to your Mac. Removes the LaunchAgent if turned off.")

        let updateBtn = NSButton(title: "Check for updates", target: self, action: #selector(checkForUpdates))
        updateBtn.bezelStyle = .roundRect
        let updateRow = NSStackView(views: [updateBtn])
        updateRow.orientation = .horizontal

        let hintLabel2 = NSTextField(wrappingLabelWithString:
            "When the menu-bar widget is hidden, relaunch from Finder to open Settings.")
        hintLabel2.textColor = .secondaryLabelColor
        hintLabel2.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        hintLabel2.preferredMaxLayoutWidth = 460

        statusLabel = NSTextField(wrappingLabelWithString: " ")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 460

        let genControls = NSStackView(views: [launchRow, updateRow, hintLabel2, statusLabel])
        genControls.orientation = .vertical
        genControls.alignment = .leading
        genControls.spacing = 8
        let genSection = makeSection(iconView: makeAppIconView(), controls: genControls)

        // ── Stack the three sections (with hairline dividers) ───────────────
        let sectionStack = NSStackView(views: [
            tokenSection, sectionDivider(), menuSection, sectionDivider(), genSection,
        ])
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 14
        sectionStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Action buttons row [Test fetch] [Save] ──────────────────────────
        let testBtn = NSButton(title: "Test fetch", target: self, action: #selector(testFetch))
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        let buttonStack = NSStackView(views: [spacer, testBtn, saveBtn])
        buttonStack.orientation = .horizontal
        buttonStack.spacing = 8
        buttonStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Footer (author | version) ───────────────────────────────────────
        let by = NSTextField(labelWithString: "Made by ibr")
        by.textColor = .tertiaryLabelColor
        by.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        by.alignment = .center

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let ver = NSTextField(labelWithString: "v\(version)")
        ver.textColor = .tertiaryLabelColor
        ver.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        let leftPad = NSView()
        leftPad.translatesAutoresizingMaskIntoConstraints = false
        let footerStack = NSStackView(views: [leftPad, by, ver])
        footerStack.orientation = .horizontal
        footerStack.distribution = .fill
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerStack.translatesAutoresizingMaskIntoConstraints = false
        by.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Equal-width left/right ensures `by` is centred. Activate AFTER the
        // stack is constructed so leftPad and ver share footerStack as a
        // common ancestor (auto-layout requires that for activation).
        leftPad.widthAnchor.constraint(equalTo: ver.widthAnchor).isActive = true

        // ── Outer container layout ──────────────────────────────────────────
        container.addSubview(sectionStack)
        container.addSubview(buttonStack)
        container.addSubview(footerStack)

        NSLayoutConstraint.activate([
            sectionStack.topAnchor.constraint(equalTo: wave.bottomAnchor, constant: 12),
            sectionStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            sectionStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: footerStack.topAnchor, constant: -12),

            footerStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            footerStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            footerStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container

        // ── Initial values ──────────────────────────────────────────────────
        modePopup.selectItem(at: Settings.shared.tokenSource.rawValue)
        fileField.stringValue = Settings.shared.customFilePath
        shellField.stringValue = Settings.shared.customShellCommand
        pollField.stringValue = String(Int(Settings.shared.pollIntervalSeconds))
        masterSwitch.state = Settings.shared.menubarEnabled ? .on : .off
        pctSwitch.state    = Settings.shared.showPercentage ? .on : .off
        waveSwitch.state   = Settings.shared.showWave       ? .on : .off
        resetSwitch.state  = Settings.shared.showResetTime  ? .on : .off
        launchSwitch.state = Settings.shared.launchAtStartup ? .on : .off
        applyMasterState()
        modeChanged()
    }

    // ── Section helpers ──────────────────────────────────────────────────────

    private func sectionDivider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 660).isActive = true
        return box
    }

    private func makeSection(iconView: NSView, controls: NSStackView) -> NSView {
        // Container: 150px icon column on the left, controls on the right
        iconView.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        let iconWrap = NSView()
        iconWrap.translatesAutoresizingMaskIntoConstraints = false
        iconWrap.addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: iconWrap.topAnchor),
            iconView.leadingAnchor.constraint(equalTo: iconWrap.leadingAnchor, constant: 14),
            iconView.bottomAnchor.constraint(lessThanOrEqualTo: iconWrap.bottomAnchor),
            iconWrap.widthAnchor.constraint(equalToConstant: 150),
        ])
        let row = NSStackView(views: [iconWrap, controls])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 18
        return row
    }

    private func makeKeyArt(_ text: String) -> NSView {
        // Bordered rectangle with a dot indicator — minimal credentials.json glyph.
        let v = NSView()
        v.wantsLayer = true
        let layer = v.layer!
        layer.borderColor = NSColor.tertiaryLabelColor.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 8
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer!.backgroundColor = NSColor.secondaryLabelColor.cgColor
        dot.layer!.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        v.addSubview(dot)
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 110),
            v.heightAnchor.constraint(equalToConstant: 60),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            dot.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
        ])
        return v
    }

    private func makeMenubarArt() -> NSView {
        // Tiny mock of the menu-bar widget on a dark pill. Stored on the
        // controller so toggle changes can hide/show individual parts.
        let v = NSView()
        v.wantsLayer = true
        v.layer!.backgroundColor = NSColor(white: 0.15, alpha: 1.0).cgColor
        v.layer!.cornerRadius = 6
        v.layer!.borderColor = NSColor.separatorColor.cgColor
        v.layer!.borderWidth = 1

        mockPct = NSTextField(labelWithString: "12%")
        mockPct.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mockPct.textColor = .white
        mockBars = NSTextField(labelWithString: "▆▇█▇▆▆▅▅▄▃")
        mockBars.font = NSFont.monospacedSystemFont(ofSize: 7, weight: .regular)
        mockBars.textColor = .white
        mockReset = NSTextField(labelWithString: "3:26")
        mockReset.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        mockReset.textColor = .white

        let row = NSStackView(views: [mockPct, mockBars, mockReset])
        row.orientation = .horizontal
        row.spacing = 4
        row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(row)
        NSLayoutConstraint.activate([
            row.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            v.widthAnchor.constraint(greaterThanOrEqualToConstant: 130),
            v.heightAnchor.constraint(equalToConstant: 28),
        ])
        mockContainer = v
        return v
    }

    /// Mirror the toggle state into the live preview mock to the left of
    /// the toggles. NSStackView removes hidden subviews from layout so the
    /// pill naturally narrows as parts are turned off.
    private func applyMockToToggles() {
        guard mockContainer != nil else { return }
        let masterOn = masterSwitch.state == .on
        // When master is off, fade the whole pill to ~empty/disabled.
        mockContainer.alphaValue = masterOn ? 1.0 : 0.25
        mockPct.isHidden   = !(masterOn && pctSwitch.state == .on)
        mockBars.isHidden  = !(masterOn && waveSwitch.state == .on)
        mockReset.isHidden = !(masterOn && resetSwitch.state == .on)
    }

    private func makeAppIconView() -> NSView {
        // Load AppIcon.icns from the bundle and display at 76×76 with a subtle
        // border so it's visible against the (possibly white) settings bg.
        let v = NSImageView()
        v.image = NSApp.applicationIconImage  // grabs the bundle icon
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.cornerRadius = 17
        v.layer?.masksToBounds = true
        v.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
        v.layer?.borderWidth = 1
        v.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            v.widthAnchor.constraint(equalToConstant: 76),
            v.heightAnchor.constraint(equalToConstant: 76),
        ])
        return v
    }

    private func makeFieldRow(_ label: String, field: NSTextField, fieldWidth: CGFloat = 380) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: fieldWidth).isActive = true
        let row = NSStackView(views: [lbl, field])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func makeRow(_ label: String, control: NSView, info: String? = nil) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        if let info = info { attachTooltip(info, to: row) }
        return row
    }

    /// Build an NSSwitch wired to the toggleChanged handler.
    private func makeSwitch() -> NSSwitch {
        let sw = NSSwitch()
        sw.target = self
        sw.action = #selector(toggleChanged(_:))
        return sw
    }

    /// Horizontal "[label] ........... [switch]" row with a flexible spacer.
    /// All toggle rows share the same width so switches stack vertically aligned
    /// across master, sub, and other sections. Font size uses the system
    /// constant so user-level accessibility text-size adjustments propagate.
    private func makeToggleRow(_ label: String, sw: NSSwitch, bold: Bool = false, info: String? = nil) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = bold
            ? .boldSystemFont(ofSize: NSFont.systemFontSize)
            : NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [lbl, spacer, sw])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 460).isActive = true
        if let info = info { attachTooltip(info, to: row) }
        return row
    }

    // ── Click-to-explain tooltips ────────────────────────────────────────────

    private var activeTooltip: NSPopover?
    private var tooltipMessages: [ObjectIdentifier: String] = [:]

    /// Attach a click-to-explain popover to a row. We attach the click
    /// recognizer to the label inside the row (the first arranged subview),
    /// not the row itself — so clicking the switch/dropdown still toggles
    /// the control normally instead of popping a tooltip.
    /// The whole row also gets a `toolTip` for hover-fallback.
    private func attachTooltip(_ message: String, to row: NSView) {
        let target: NSView
        if let stack = row as? NSStackView, let first = stack.arrangedSubviews.first {
            target = first
        } else {
            target = row
        }
        tooltipMessages[ObjectIdentifier(target)] = message
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked(_:)))
        target.addGestureRecognizer(click)
        row.toolTip = message
    }

    @objc private func rowClicked(_ sender: NSClickGestureRecognizer) {
        guard let target = sender.view,
              let message = tooltipMessages[ObjectIdentifier(target)] else { return }
        showTooltip(message, anchor: target)
    }

    private func showTooltip(_ text: String, anchor: NSView) {
        activeTooltip?.close()
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = .labelColor
        label.preferredMaxLayoutWidth = 240
        label.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSView()
        inner.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: inner.topAnchor, constant: 10),
            label.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -10),
            label.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -14),
        ])
        // NSPopover needs an explicit contentSize — the contentViewController's
        // view doesn't have an intrinsic size by default, so without this the
        // popover renders blank/zero. Compute height from the wrapped label.
        inner.layoutSubtreeIfNeeded()
        let labelSize = label.fittingSize
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = {
            let vc = NSViewController()
            vc.view = inner
            return vc
        }()
        popover.contentSize = NSSize(
            width:  min(280, max(120, labelSize.width + 28)),
            height: max(36, labelSize.height + 20))
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        activeTooltip = popover
    }

    /// Master OFF → disable + grey out the sub toggles. Master ON → normal.
    /// Also pushes the new state into the live preview mock.
    private func applyMasterState() {
        let on = masterSwitch.state == .on
        for sw in [pctSwitch, waveSwitch, resetSwitch] { sw?.isEnabled = on }
        subTogglesStack.alphaValue = on ? 1.0 : 0.4
        applyMockToToggles()
    }

    /// master ON  → restore all subs to ON (sane default).
    /// sub flips, all subs end up OFF → master flips OFF too.
    @objc func toggleChanged(_ sender: NSSwitch) {
        if sender == masterSwitch {
            if masterSwitch.state == .on {
                pctSwitch.state = .on
                waveSwitch.state = .on
                resetSwitch.state = .on
            }
        } else {
            if pctSwitch.state == .off && waveSwitch.state == .off && resetSwitch.state == .off {
                masterSwitch.state = .off
            }
        }
        applyMasterState()
    }

    @objc func modeChanged() {
        let mode = TokenSource(rawValue: modePopup.indexOfSelectedItem) ?? .auto
        switch mode {
        case .auto:
            hintLabel.stringValue = "We'll try common locations like " + knownCredentialPaths.first! + " and pick the first one that has a valid token."
            fileRow.isHidden = true
            shellRow.isHidden = true
        case .file:
            hintLabel.stringValue = "Path to a Claude credentials JSON or a file containing just the access token."
            fileRow.isHidden = false
            shellRow.isHidden = true
        case .shell:
            hintLabel.stringValue = "A shell command that prints credentials JSON or a token to stdout. Useful when Claude runs in Docker, on a remote machine over SSH, etc."
            fileRow.isHidden = true
            shellRow.isHidden = false
        }
    }

    func collect() {
        Settings.shared.tokenSource = TokenSource(rawValue: modePopup.indexOfSelectedItem) ?? .auto
        Settings.shared.customFilePath = fileField.stringValue
        Settings.shared.customShellCommand = shellField.stringValue
        if let n = Double(pollField.stringValue) {
            Settings.shared.pollIntervalSeconds = max(30, n)
        }
        Settings.shared.menubarEnabled = masterSwitch.state == .on
        Settings.shared.showPercentage = pctSwitch.state == .on
        Settings.shared.showWave       = waveSwitch.state == .on
        Settings.shared.showResetTime  = resetSwitch.state == .on
        Settings.shared.launchAtStartup = launchSwitch.state == .on
    }

    @objc func checkForUpdates() {
        if let url = URL(string: "https://github.com/ibrarwtf/claude-limits/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func save() {
        collect()
        onSave?()
        view.window?.close()
    }

    @objc func testFetch() {
        collect()
        statusLabel.stringValue = "Testing…"
        statusLabel.textColor = .secondaryLabelColor
        fetchUsage { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .success(let u):
                    if let f = u.fiveHour {
                        self.statusLabel.stringValue = "OK — current session at \(Int(round(f.utilization)))%"
                    } else {
                        self.statusLabel.stringValue = "Connected, but no five_hour data."
                    }
                    self.statusLabel.textColor = .labelColor
                case .failure(let e):
                    self.statusLabel.stringValue = "\(e.friendlyMessage)"
                    self.statusLabel.textColor = .labelColor
                }
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────────────────────
// MARK: - main
// ──────────────────────────────────────────────────────────────────────────────

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
