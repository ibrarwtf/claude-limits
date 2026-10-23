import AppKit
import Foundation
import UserNotifications

extension URL {
    func queryParam(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
    }
}

/// Tabular row with a graphical progress bar — drawn (not text characters)
/// so it fills the full column and the height isn't tied to font metrics.
final class TabularRowView: NSView {
    static let height: CGFloat = 24
    let label: String
    let utilization: Double
    let value: String
    weak var menuItem: NSMenuItem?

    init(label: String, utilization: Double, value: String, width: CGFloat) {
        self.label = label
        self.utilization = utilization
        self.value = value
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isHl = (menuItem?.isHighlighted ?? false) && (menuItem?.isEnabled ?? true)
        Self.paint(label: label, utilization: utilization, value: value,
                   bounds: bounds, isHighlighted: isHl, origin: .zero)
    }

    /// Drawing extracted as static so the synthetic dropdown can paint the
    /// same tabular row directly into its canvas — no cacheDisplay (which
    /// has appearance-resolution issues on offscreen contexts).
    static func paint(label: String, utilization: Double, value: String,
                      bounds: NSRect, isHighlighted: Bool, origin: NSPoint) {
        if isHighlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSRect(origin: origin, size: bounds.size).fill()
        }
        // Faded text — these rows are info-only, not interactive.
        let textColor: NSColor = isHighlighted ? .selectedMenuItemTextColor : .secondaryLabelColor
        let font = NSFont.menuFont(ofSize: 0)

        let leftPad = MenuRowView.leftPad
        let rightPad = MenuRowView.rightPad
        let labelW: CGFloat = 90
        let labelGap: CGFloat = 8
        let barValueGap: CGFloat = 6   // small breathing room between bar and value
        let barH: CGFloat = 10
        let barY = origin.y + (bounds.height - barH) / 2
        let textY = origin.y + (bounds.height - font.pointSize) / 2 - 2

        // Measure value first so the bar can extend right up to it.
        let valueAttr = NSAttributedString(string: value, attributes: [
            .font: font, .foregroundColor: textColor,
        ])
        let vSize = valueAttr.size()
        let valueX = origin.x + bounds.width - rightPad - vSize.width

        let barX = origin.x + leftPad + labelW + labelGap
        let barW = valueX - barX - barValueGap

        // Label
        NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: textColor,
        ]).draw(at: NSPoint(x: origin.x + leftPad, y: textY))

        // Segmented bar: many small discrete blocks. Block count tuned so each
        // block is ~5pt wide for fine granularity without looking like a
        // solid bar.
        let blockCount = 24
        let blockGap: CGFloat = 1
        let blockW = (barW - CGFloat(blockCount - 1) * blockGap) / CGFloat(blockCount)
        let fillFrac = max(0, min(1, utilization / 100.0))
        var filledBlocks = Int(round(Double(blockCount) * fillFrac))
        // Any nonzero usage lights at least one block, so a small-but-real value
        // never renders as an empty (0%) bar next to a nonzero numeric label.
        if utilization > 0 && filledBlocks == 0 { filledBlocks = 1 }

        let emptyColor = isHighlighted ? NSColor.white.withAlphaComponent(0.25)
                                       : NSColor.tertiaryLabelColor.withAlphaComponent(0.4)
        let fillColor  = isHighlighted ? NSColor.selectedMenuItemTextColor
                                       : NSColor.controlAccentColor

        for i in 0..<blockCount {
            let blockX = barX + CGFloat(i) * (blockW + blockGap)
            let rect = NSRect(x: blockX, y: barY, width: blockW, height: barH)
            (i < filledBlocks ? fillColor : emptyColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Value at right edge — position pre-computed above so bar extends to it.
        valueAttr.draw(at: NSPoint(x: valueX, y: textY))
    }
}

/// Custom view for menu items. NSMenu reserves ~22pt on the left of every
/// item for the state-icon column (where checkmarks would render); items
/// with `view` set bypass that, so we get flush-left text. Self-handles
/// hover highlight + click dispatch.
final class MenuRowView: NSView {
    static let rowHeight: CGFloat = 22
    static let leftPad: CGFloat = 10
    static let rightPad: CGFloat = 10

    private var titleAttr: NSAttributedString
    weak var menuItem: NSMenuItem?

    init(title: NSAttributedString, width: CGFloat) {
        self.titleAttr = title
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: Self.rowHeight))
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func updateTitle(_ attr: NSAttributedString) {
        titleAttr = attr
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let isHl = (menuItem?.isHighlighted ?? false) && (menuItem?.isEnabled ?? true)
        if isHl {
            NSColor.selectedContentBackgroundColor.setFill()
            bounds.fill()
        }
        // Always force the macOS menu font (NSFont.menuFont) so every row in
        // every state uses the same typeface and size — no AppKit defaults
        // sneaking in differently per item.
        let mut = NSMutableAttributedString(attributedString: titleAttr)
        mut.addAttribute(.font, value: NSFont.menuFont(ofSize: 0),
            range: NSRange(location: 0, length: mut.length))
        if isHl {
            mut.addAttribute(.foregroundColor,
                value: NSColor.selectedMenuItemTextColor,
                range: NSRange(location: 0, length: mut.length))
        }
        let ts = mut.size()
        let y = (bounds.height - ts.height) / 2
        mut.draw(at: NSPoint(x: Self.leftPad, y: y))
    }

    override func mouseUp(with event: NSEvent) {
        guard let item = menuItem, item.isEnabled, let action = item.action else { return }
        item.menu?.cancelTracking()
        // Defer so cancelTracking finishes before the action handler fires.
        // `to: item.target` may be nil — NSApp.sendAction then walks the
        // responder chain (needed for NSApp.terminate-style actions).
        DispatchQueue.main.async {
            NSApp.sendAction(action, to: item.target, from: item)
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var pollTimer: Timer?
    var animationTimer: Timer?
    var animationFrame = 0
    var animationStartedAt: Date?
    /// Bumped each time startAnimation() begins a cycle. Deferred stops capture
    /// this value when scheduled and no-op if a newer cycle has since started,
    /// so a stale asyncAfter can't tear down a fresh animation.
    var animationGeneration = 0
    var isRefreshing = false
    var currentTask: URLSessionDataTask?
    var currentRequestToken: UUID?
    var lastResponse: UsageResponse?
    var lastUpdated: Date?
    var lastError: AppError?
    var settingsWindow: NSWindow?
    var tickTimer: Timer?

    // Error animation cycle (cold-start only — runs only when there's no
    // prior successful data). Monotonic 12 fps counter; cyclePos picks phase.
    var rateLimitCycleTimer: Timer?
    var rateLimitAnimFrame: Int = 0

    /// Width ceiling for the status item, computed once from the worst-case
    /// "all three on" content. Slot can shrink below this when sub-toggles
    /// hide parts; nothing may grow it past this — clampWidth() enforces.
    var maxStatusItemWidth: CGFloat = 0
    var marqueeWindowChars: Int = 22

    var latestVersionAvailable: String? = nil
    var lastUpdateCheckAt: Date? = nil
    var updateCheckTimer: Timer?

    /// Click-storm guard (see cooling_down in logic/core.pl): excess clicks
    /// just play the acknowledgement wave instead of re-fetching.
    var lastManualClickAt: Date? = nil

    // Live "Last updated: Xs ago" line — refreshed once per second while the
    // dropdown is open so the counter visibly ticks up.
    weak var lastUpdatedMenuItem: NSMenuItem?
    weak var resetMenuItem: NSMenuItem?
    var menuTickTimer: Timer?
    /// Used for "next in Xs" rendering.
    var nextPollAt: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "claude-limits"
        statusItem.isVisible = true
        statusItem.button?.title = "—"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        if FixtureMode.isActive {
            startFixture()
            return
        }

        // Threshold notifications: the user can act on a heads-up at 80% / 95%
        // even with the menu bar offscreen (fullscreen apps, focus mode).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        computeWidthBudget()
        clampWidth()

        // Restore last successful response from disk so we render real data
        // immediately, even before the first poll completes.
        if let data = Settings.shared.lastResponseJSON,
           let r = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            self.lastResponse = r
            self.lastUpdated = Settings.shared.lastSuccessfulPoll
            updateTitle()
        }

        // Still inside a rate-limit window from the previous process? Mirror
        // the error state. Marquee only runs when there's no prior data.
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            self.lastError = .rateLimited(until.timeIntervalSinceNow)
            if self.lastResponse == nil {
                startRateLimitCycle()
            }
        }

        if shouldPoll(Settings.shared.nextAllowedPoll, Settings.shared.lastSuccessfulPoll, Date()) {
            triggerRefresh(animated: true)
        } else {
            updateTitle()
        }
        schedulePoll()

        // Tick the title every 30s to update the reset countdown without a fetch.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updateTitle()
        }

        // Update check: once at launch (small delay so the first poll lands
        // first), then daily. GitHub anonymous limit is 60/h, so daily is fine.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForLatestRelease()
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForLatestRelease()
        }

        if !Settings.shared.didFirstLaunch {
            Settings.shared.didFirstLaunch = true
            // Auto-enable autostart on first launch so brew-installed users
            // get a working LaunchAgent without flipping a setting. Idempotent
            // — does nothing if scripts/install.sh wrote the file already.
            Settings.shared.launchAtStartup = true
            // Async so AppKit's launch dance is done before we order a window
            // front (LSUIElement apps otherwise create the window without
            // making it visible).
            DispatchQueue.main.async { [weak self] in
                self?.openSettings()
            }
        }
    }

    /// `--fixture`: render canned data with no polling, update checks,
    /// notifications or first-launch side effects; with `--snapshot-all`,
    /// capture every view and quit (see Fixture.swift).
    func startFixture() {
        computeWidthBudget()
        lastResponse = FixtureMode.fixture?.response
        lastUpdated = Clock.now()
        nextPollAt = Clock.now().addingTimeInterval(pollInterval)
        updateTitle()
        if let dest = FixtureMode.snapshotDest {
            // Next runloop tick so the status item has laid out its title.
            DispatchQueue.main.async { [weak self] in
                self?.captureAll(dest: dest)
                NSApp.terminate(nil)
            }
        }
    }

    /// Measure the worst-case "all three on" content once at startup so every
    /// later render can clamp to it.
    func computeWidthBudget() {
        let normalFont = NSFont.menuBarFont(ofSize: NSFont.systemFontSize)
        let sparkFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let sample = NSMutableAttributedString()
        sample.append(NSAttributedString(string: "100% ", attributes: [.font: normalFont]))
        sample.append(NSAttributedString(string: "██████████",
            attributes: [.font: sparkFont, .baselineOffset: 1.0]))
        sample.append(NSAttributedString(string: " 9:59", attributes: [.font: normalFont]))
        maxStatusItemWidth = ceil(sample.size().width) + 6

        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let monoSample = NSAttributedString(string: String(repeating: "M", count: 50),
            attributes: [.font: mono])
        let charWidth = monoSample.size().width / 50.0
        marqueeWindowChars = max(8, Int(floor((maxStatusItemWidth - 6) / charWidth)))
    }

    /// Hit the GitHub Releases API and remember whether a newer version is
    /// available. UI consumers read `latestVersionAvailable` to render hints.
    func checkForLatestRelease(completion: ((String?, Error?) -> Void)? = nil) {
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.lastUpdateCheckAt = Date()
                switch result {
                case .success(let release):
                    let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
                    self.latestVersionAvailable = isNewerVersion(release.tagName, current) ? release.tagName : nil
                    completion?(self.latestVersionAvailable, nil)
                case .failure(let e):
                    completion?(nil, e)
                }
            }
        }
    }

    /// Breadcrumb posted just before we quit for a brew upgrade. The app must
    /// quit so brew can replace the bundle, so the menu-bar icon briefly
    /// vanishes — this reassures the user it's coming back. Silently no-ops if
    /// notifications weren't authorized.
    func notifyUpdating(to version: String) {
        let c = UNMutableNotificationContent()
        c.title = "Updating claude-limits"
        c.body = "Installing \(version) — the menu bar icon will return in a few seconds."
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "claude-limits.updating", content: c, trigger: nil))
    }

    /// Resize slot to fit current title, capped at maxStatusItemWidth.
    /// Called at the end of every render path.
    func clampWidth() {
        var width: CGFloat = 0
        if let attr = statusItem.button?.attributedTitle, attr.length > 0 {
            width = ceil(attr.size().width) + 6
        } else if let plain = statusItem.button?.title, !plain.isEmpty {
            let f = NSFont.menuBarFont(ofSize: NSFont.systemFontSize)
            width = ceil(NSAttributedString(string: plain, attributes: [.font: f]).size().width) + 6
        }
        statusItem.length = min(max(width, 24), maxStatusItemWidth)
    }

    func schedulePoll() {
        pollTimer?.invalidate()
        nextPollAt = Date().addingTimeInterval(pollInterval)
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.nextPollAt = Date().addingTimeInterval(pollInterval)
            if self.shouldPoll(Settings.shared.nextAllowedPoll, Settings.shared.lastSuccessfulPoll, Date()) { self.triggerRefresh(animated: false) }
            else { self.updateTitle() }
        }
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showDropdown()
            return
        }
        // Rate-limited → click-acknowledgement wave only, no fetch.
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            lastError = .rateLimited(until.timeIntervalSinceNow)
            playClickAnimation()
            return
        }
        // Click-storm cooldown → wave only, no fetch.
        if coolingDown(lastManualClickAt, Date()) {
            playClickAnimation()
            return
        }
        lastManualClickAt = Date()
        triggerRefresh(animated: true, force: true)
    }

    private func playClickAnimation() {
        startAnimation()
        let gen = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, self.animationGeneration == gen else { return }
            self.stopAnimation()
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

    /// Custom menu views don't auto-redraw on highlight changes — NSMenu
    /// fires this when an item is about to be highlighted (or de-highlighted
    /// when nil); mark every view dirty so the row repaints.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for menuItem in menu.items {
            menuItem.view?.needsDisplay = true
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
        menuTickTimer?.invalidate()
        menuTickTimer = nil
        lastUpdatedMenuItem = nil
        resetMenuItem = nil
    }

    func tickMenuLastUpdated() {
        if let view = lastUpdatedMenuItem?.view as? MenuRowView {
            view.updateTitle(NSAttributedString(
                string: formatTopStatusLine(),
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
        if let view = resetMenuItem?.view as? MenuRowView,
           let r = lastResponse, let f = r.fiveHour {
            view.updateTitle(NSAttributedString(
                string: formatResetLine(f),
                attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        }
    }

    // ── Title rendering ──────────────────────────────────────────────────────

    func updateTitle() {
        if isRefreshing || animationTimer != nil { return }
        if rateLimitCycleTimer != nil { return }

        statusItem.isVisible = true

        if let err = lastError, lastResponse == nil {
            statusItem.button?.title = errorSymbol(err)
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
            clampWidth()
            return
        }
        if let r = lastResponse, let f = r.fiveHour {
            let pct = percent(f.utilization)
            let spark = sparkline(UsageHistory.shared.samples, sparkWidth)
            let resetStr = countdown(f.resetsAt, Clock.now())
            let normalFont = NSFont.menuBarFont(ofSize: NSFont.systemFontSize)
            let sparkFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
            let normalAttrs: [NSAttributedString.Key: Any] = [.font: normalFont]
            let sparkAttrs: [NSAttributedString.Key: Any] = [
                .font: sparkFont,
                .baselineOffset: 1.0,
            ]
            let title = NSMutableAttributedString()
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
            if s.showResetTime, let resetStr = resetStr {
                if prevAdded { title.append(NSAttributedString(string: " ", attributes: normalAttrs)) }
                title.append(NSAttributedString(string: resetStr, attributes: normalAttrs))
                prevAdded = true
            }
            // All sub-toggles off — show a single dot so the click target stays alive.
            if !prevAdded {
                statusItem.button?.title = "·"
                statusItem.button?.attributedTitle = NSAttributedString(string: "")
                clampWidth()
                return
            }
            statusItem.button?.attributedTitle = title
        } else {
            statusItem.button?.title = "—"
            statusItem.button?.attributedTitle = NSAttributedString(string: "")
        }
        clampWidth()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    // Snapshot capture (URL handler + render*PNG) lives in Snapshot.swift.

    // ── Refresh + animation ──────────────────────────────────────────────────

    /// Record a 429 and return the "do not poll until" deadline. Shared by the
    /// poller and Settings "Test fetch" so no entry point can skip the back-off.
    @discardableResult
    func recordRateLimit(_ retry: TimeInterval?) -> Date {
        Settings.shared.consecutiveRateLimits += 1
        let until = Date().addingTimeInterval(backoffSecs(Settings.shared.consecutiveRateLimits, retry))
        Settings.shared.nextAllowedPoll = until
        return until
    }

    func triggerRefresh(animated: Bool, force: Bool = false) {
        if isRefreshing && !force { return }
        if force, let t = currentTask { t.cancel() }
        isRefreshing = true
        if animated { startAnimation() }
        // Manual refreshes push the periodic timer's next-fire forward by a
        // full interval so we don't double-poll right after a manual click.
        if force { schedulePoll() }
        let myToken = UUID()
        currentRequestToken = myToken
        fetchUsage(taskHandle: { [weak self] task in
            self?.currentTask = task
        }) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.currentRequestToken != myToken { return }
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
                        self.checkAndNotifyThresholds(f)
                    }
                case .failure(let e):
                    self.lastError = e
                    UsageHistory.shared.appendError()
                    if case .rateLimited(let retry) = e {
                        let until = self.recordRateLimit(retry)
                        let count = Settings.shared.consecutiveRateLimits
                        let secs = Int(round(until.timeIntervalSinceNow))
                        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
                        NSLog("claude-limits rate limited (#\(count)) — next attempt at \(f.string(from: until)) (waiting \(secs)s)")
                    } else {
                        NSLog("claude-limits fetch error: \(friendlyMessage(e))")
                    }
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
        animationGeneration += 1

        let sparkFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .regular)
        let normalFont = NSFont.menuBarFont(ofSize: NSFont.systemFontSize)
        let sparkAttrs: [NSAttributedString.Key: Any] = [
            .font: sparkFont,
            .baselineOffset: 1.0,
        ]

        let normalAttrs: [NSAttributedString.Key: Any] = [.font: normalFont]
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let frame = waveFrame(self.animationFrame)
            // Slot-machine reels: % and reset spin while bars dance. Each
            // piece is gated by its visibility toggle so a hidden part stays
            // hidden during the click-acknowledgement animation.
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
            if !prev {
                self.statusItem.button?.title = "·"
                self.statusItem.button?.attributedTitle = NSAttributedString(string: "")
            } else {
                self.statusItem.button?.attributedTitle = title
            }
            self.clampWidth()
            self.animationFrame += 1
        }
    }

    func scheduleAnimationStop() {
        let elapsed = animationStartedAt.map { Date().timeIntervalSince($0) } ?? minAnimation
        let remaining = max(0, minAnimation - elapsed)
        if remaining <= 0 { stopAnimation() }
        else {
            let gen = animationGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self = self, self.animationGeneration == gen else { return }
                self.stopAnimation()
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
    // Phase A bouncing wave (~1.5s), Phase B marquee scroll of friendly
    // message. Both render mono within the width budget.

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

    func tickRateLimitCycle() {
        if lastError == nil {
            stopRateLimitCycle()
            updateTitle()
            return
        }
        if case .rateLimited = lastError ?? .parseFailed(""),
           let until = Settings.shared.nextAllowedPoll,
           until <= Date() {
            stopRateLimitCycle()
            updateTitle()
            return
        }
        let text = errorFrame(rateLimitAnimFrame, marqueeText(lastError!, Settings.shared.nextAllowedPoll, Date()), marqueeWindowChars)
        guard let text = text else {
            stopRateLimitCycle()
            updateTitle()
            return
        }
        let mono = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        statusItem.button?.attributedTitle = NSAttributedString(
            string: text, attributes: [.font: mono, .foregroundColor: NSColor.labelColor])
        clampWidth()
        rateLimitAnimFrame += 1
    }

    // ── Menu rendering ───────────────────────────────────────────────────────

    func formatResetLine(_ f: UsageBucket) -> String {
        resetLine(f.utilization, f.resetsAt, UsageHistory.shared.samples, Clock.now())
    }

    /// Fire one-shot notifications when 5h utilization first crosses 80% / 95%.
    /// State is keyed to the live `resets_at` so each new window starts fresh,
    /// and a relaunch mid-window won't re-notify.
    func checkAndNotifyThresholds(_ f: UsageBucket) {
        let s = Settings.shared
        // Only roll over the dedup set on a real resets_at change. The API can
        // intermittently drop resets_at to nil mid-window; treating that as a
        // rollover would clear the set and re-fire the 80/95% alerts for a
        // window we already notified.
        if let r = f.resetsAt, r != s.lastNotifiedResetsAt {
            s.lastNotifiedResetsAt = r
            s.notifiedThresholds = []
        }
        var fired = s.notifiedThresholds
        for threshold in crossed(f.utilization, Array(fired)) {
            let c = UNMutableNotificationContent()
            c.title = alertTitle(threshold)
            c.body = alertBody(threshold)
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "claude-limits.threshold.\(threshold).\(s.lastNotifiedResetsAt ?? "")",
                content: c, trigger: nil))
            fired.insert(threshold)
        }
        s.notifiedThresholds = fired
    }

    func formatTopStatusLine() -> String {
        statusLine(lastError, lastUpdated, Settings.shared.nextAllowedPoll, nextPollAt, Clock.now())
    }

    /// Default width for menu rows. NSMenu auto-sizes to widest item; using
    /// a single shared width keeps every row visually flush right + left.
    static let menuRowWidth: CGFloat = 360

    /// Wrap an NSMenuItem with a MenuRowView so it renders flush-left
    /// (no icon column) and uses a single consistent font. Also sets
    /// attributedTitle so the synthetic dropdown render uses the same
    /// attributed string the view draws.
    private func wrapAsView(_ item: NSMenuItem, attr: NSAttributedString) {
        item.attributedTitle = attr
        let view = MenuRowView(title: attr, width: AppDelegate.menuRowWidth)
        view.menuItem = item
        item.view = view
    }

    /// Section header — dimmed colour, default menu font, non-clickable.
    func sectionHeader(_ s: String) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        wrapAsView(item, attr: NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return item
    }

    func plainItem(_ s: String, dim: Bool = false, color: NSColor? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let fg: NSColor = color ?? (dim ? NSColor.secondaryLabelColor : NSColor.labelColor)
        wrapAsView(item, attr: NSAttributedString(string: s, attributes: [.foregroundColor: fg]))
        return item
    }

    /// Tabular row: label, graphical progress bar that fills the column,
    /// then the value flush-right. Uses TabularRowView so the bar is drawn
    /// (not text glyphs), can be sized independently of font metrics, and
    /// spans the full available width.
    func tabularItem(label: String, utilization: Double, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label) \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        let view = TabularRowView(label: label, utilization: utilization, value: value,
                                  width: AppDelegate.menuRowWidth)
        view.menuItem = item
        item.view = view
        return item
    }

    /// Single-line label-on-left, value-on-right — no progress bar.
    /// Used for Pay-as-you-go and similar.
    func payAsYouGoItem(label: String, value: String) -> NSMenuItem {
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .right,
                                   location: AppDelegate.menuRowWidth - MenuRowView.rightPad - MenuRowView.leftPad)]
        let s = "\(label)\t\(value)"
        let item = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        item.isEnabled = false
        wrapAsView(item, attr: NSAttributedString(string: s, attributes: [
            .paragraphStyle: para,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return item
    }

    /// Action row — clickable, default menu font.
    /// `target == nil` walks the responder chain (needed for NSApp.terminate
    /// which lives on NSApp, not AppDelegate).
    func actionItem(_ s: String, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: action, keyEquivalent: "")
        item.target = target
        wrapAsView(item, attr: NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.labelColor,
        ]))
        return item
    }

    func buildMenu(into menu: NSMenu) {
        let topItem = plainItem(formatTopStatusLine(), dim: true)
        menu.addItem(topItem)
        lastUpdatedMenuItem = topItem

        if let err = lastError {
            if case .tokenNotFound = err {
                menu.addItem(actionItem("→ Open Settings", action: #selector(openSettings)))
            }
        }

        // Update-available hint lives in Settings (SettingsWindow renders the
        // status line there) — keep the dropdown clean.
        menu.addItem(.separator())

        if let r = lastResponse, let f = r.fiveHour {
            let resetItem = plainItem(formatResetLine(f), dim: true)
            menu.addItem(resetItem)
            resetMenuItem = resetItem
        }

        if let r = lastResponse {
            let active = weeklyRows(r)
            if !active.isEmpty {
                menu.addItem(.separator())
                menu.addItem(sectionHeader("Weekly limits"))
                for (label, bucket) in active {
                    let pct = "\(percent(bucket.utilization))%"
                    menu.addItem(tabularItem(label: label, utilization: bucket.utilization, value: pct))
                }
            }
        }

        if let r = lastResponse, let extra = r.extraUsage, extra.isEnabled == true {
            menu.addItem(.separator())
            // Single-line: "Pay-as-you-go credits" on the left, "X.XX / Y.YY USD"
            // flush-right via tab stop. Same layout idiom as the tabular rows.
            let value = creditsText(extra.usedCredits ?? 0, extra.monthlyLimit ?? 0, extra.currency ?? "USD")
            menu.addItem(payAsYouGoItem(label: "Pay-as-you-go credits", value: value))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh now", action: #selector(refreshAction), target: self))
        menu.addItem(actionItem("Open claude.ai/settings/usage", action: #selector(openUsageWeb), target: self))
        menu.addItem(actionItem("Settings…", action: #selector(openSettings), target: self))
        menu.addItem(.separator())
        // target=NSApp — terminate(_:) is on NSApp, not AppDelegate.
        menu.addItem(actionItem("Quit claude-limits", action: #selector(NSApp.terminate(_:)), target: NSApp))
    }

    @objc func refreshAction() {
        if let until = Settings.shared.nextAllowedPoll, until > Date() { return }
        // Share the status-item click-storm cooldown so repeated "Refresh now"
        // taps can't bypass the throttle clicked(_:) enforces.
        if coolingDown(lastManualClickAt, Date()) {
            playClickAnimation()
            return
        }
        lastManualClickAt = Date()
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
        // LSUIElement apps stay at .accessory permanently. makeKeyAndOrderFront
        // alone doesn't reliably foreground from menu-driven calls (previous
        // app keeps focus); we pair it with activate(ignoringOtherApps:) and
        // orderFrontRegardless(). Toggling activation policy to .regular and
        // back closes any window that became visible during it.
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}
