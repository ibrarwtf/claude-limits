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

/// Row with a drawn segmented bar (not text glyphs) that fills the column.
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

    /// Static so the synthetic dropdown paints it directly (cacheDisplay
    /// mis-resolves appearance offscreen).
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

        NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: textColor,
        ]).draw(at: NSPoint(x: origin.x + leftPad, y: textY))

        // ~5pt blocks: fine granularity without reading as a solid bar.
        let blockCount = 24
        let blockGap: CGFloat = 1
        let blockW = (barW - CGFloat(blockCount - 1) * blockGap) / CGFloat(blockCount)
        let filled = filledBlocks(utilization, blockCount)

        let emptyColor = isHighlighted ? NSColor.white.withAlphaComponent(0.25)
                                       : NSColor.tertiaryLabelColor.withAlphaComponent(0.4)
        let fillColor  = isHighlighted ? NSColor.selectedMenuItemTextColor
                                       : NSColor.controlAccentColor

        for i in 0..<blockCount {
            let blockX = barX + CGFloat(i) * (blockW + blockGap)
            let rect = NSRect(x: blockX, y: barY, width: blockW, height: barH)
            (i < filled ? fillColor : emptyColor).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }

        valueAttr.draw(at: NSPoint(x: valueX, y: textY))
    }
}

/// NSMenu reserves ~22pt for the state-icon column; a `view` bypasses it,
/// giving flush-left text. Handles its own hover + click.
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
        // Always NSFont.menuFont so every row and state matches.
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
    /// Bumped per startAnimation(); a deferred stop from an older cycle no-ops.
    var animationGeneration = 0
    var isRefreshing = false
    var currentTask: URLSessionDataTask?
    var currentRequestToken: UUID?
    var lastResponse: UsageResponse?
    var lastUpdated: Date?
    var lastError: AppError?
    var settingsWindow: NSWindow?
    var tickTimer: Timer?

    // Cold-start error animation counter (error_tick in logic/core.pl).
    var rateLimitCycleTimer: Timer?
    var rateLimitAnimFrame: Int = 0

    /// Status-item width ceiling from the "all three on" content; clampWidth() enforces.
    var maxStatusItemWidth: CGFloat = 0
    var marqueeWindowChars: Int = 22

    var latestVersionAvailable: String? = nil
    var updateCheckTimer: Timer?

    /// Click-storm guard (see cooling_down in logic/core.pl): excess clicks
    /// just play the acknowledgement wave instead of re-fetching.
    var lastManualClickAt: Date? = nil

    // Ticks "Last updated: Xs ago" each second while the dropdown is open.
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

        // 80% / 95% alerts reach users with the menu bar offscreen (fullscreen, focus).
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        computeWidthBudget()
        clampWidth()

        // Show the last response straight away, before the first poll lands.
        if let data = Settings.shared.lastResponseJSON,
           let r = try? JSONDecoder().decode(UsageResponse.self, from: data) {
            self.lastResponse = r
            self.lastUpdated = Settings.shared.lastSuccessfulPoll
            updateTitle()
        }

        // Still inside a 429 back-off from the previous process: mirror it.
        lastError = backoffError(Settings.shared.nextAllowedPoll, Date())
        if lastError != nil && lastResponse == nil { startRateLimitCycle() }

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

        // Update check shortly after launch, then daily (GitHub allows 60/h anonymous).
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForLatestRelease()
        }
        updateCheckTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            self?.checkForLatestRelease()
        }

        if !Settings.shared.didFirstLaunch {
            Settings.shared.didFirstLaunch = true
            // Brew installs get a LaunchAgent without flipping a setting (idempotent).
            Settings.shared.launchAtStartup = true
            // Async: LSUIElement apps don't show windows during the launch dance.
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

    /// Worst-case "all three on" width, measured once so renders can clamp to it.
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

    /// Remembers a newer release in latestVersionAvailable (Settings shows it).
    func checkForLatestRelease(completion: ((String?, Error?) -> Void)? = nil) {
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let release):
                    let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
                    self.latestVersionAvailable = isNewerVersion(release.tagName ?? "", current) ? release.tagName : nil
                    completion?(self.latestVersionAvailable, nil)
                case .failure(let e):
                    completion?(nil, e)
                }
            }
        }
    }

    /// Posted before quitting for a brew upgrade, while the icon is gone.
    /// No-ops if notifications weren't authorized.
    func notifyUpdating(to version: String) {
        let c = UNMutableNotificationContent()
        c.title = "Updating claude-limits"
        c.body = updatingNotice(version, "menu bar icon")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "claude-limits.updating", content: c, trigger: nil))
    }

    /// Fit the slot to the title, capped at maxStatusItemWidth. Ends every render.
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
            if shouldPoll(Settings.shared.nextAllowedPoll, Settings.shared.lastSuccessfulPoll, Date()) { self.triggerRefresh(animated: false) }
            else { self.updateTitle() }
        }
    }

    @objc func clicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
            showDropdown()
            return
        }
        manualRefresh(fromClick: true)
    }

    /// See click_effect in logic/core.pl. "Refresh now" shares the click-storm
    /// cooldown but stays silent during a 429 back-off.
    func manualRefresh(fromClick: Bool) {
        switch clickEffect(Settings.shared.nextAllowedPoll, lastManualClickAt, Date()) {
        case .blocked:
            guard fromClick else { return }
            lastError = backoffError(Settings.shared.nextAllowedPoll, Date())
            playClickAnimation()
        case .cooling: playClickAnimation()
        case .fetch:
            lastManualClickAt = Date()
            triggerRefresh(animated: true, force: true)
        }
    }

    private func playClickAnimation() { startAnimation(); stopAnimation(after: 1.5) }

    func showDropdown() {
        let menu = NSMenu()
        menu.delegate = self
        buildMenu(into: menu)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ menu: NSMenu) {
        // .common so it keeps firing during menu tracking.
        menuTickTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tickMenuLastUpdated()
        }
        RunLoop.current.add(timer, forMode: .common)
        menuTickTimer = timer
    }

    /// Custom menu views don't repaint on highlight changes; dirty them all.
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
        if isRefreshing || animationTimer != nil || rateLimitCycleTimer != nil { return }
        statusItem.isVisible = true
        if let err = lastError, lastResponse == nil { return setPlainTitle(errorSymbol(err)) }
        if let f = lastResponse?.fiveHour {
            let s = Settings.shared
            setTitle(titleParts(s.showPercentage, s.showWave, s.showResetTime, "\(percent(f.utilization))%",
                                sparkline(UsageHistory.shared.samples, sparkWidth), countdown(f.resetsAt, Clock.now())))
            return
        }
        setPlainTitle("—")
    }

    func setPlainTitle(_ text: String) {
        statusItem.button?.title = text
        statusItem.button?.attributedTitle = NSAttributedString(string: "")
        clampWidth()
    }

    /// Menu-bar text from title_parts: the sparkline in a small mono font, the rest
    /// in the menu-bar font; no parts → a lone dot so the click target stays alive.
    func setTitle(_ parts: [Part]) {
        let normal: [NSAttributedString.Key: Any] = [.font: NSFont.menuBarFont(ofSize: NSFont.systemFontSize)]
        let spark: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 8, weight: .regular), .baselineOffset: 1.0]
        if parts.isEmpty { return setPlainTitle("·") }
        let title = NSMutableAttributedString()
        for (i, part) in parts.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: " ", attributes: normal)) }
            switch part {
            case .spark(let v): title.append(NSAttributedString(string: v, attributes: spark))
            case .pct(let v), .reset(let v): title.append(NSAttributedString(string: v, attributes: normal))
            }
        }
        statusItem.button?.attributedTitle = title
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
        // A manual refresh restarts the poll timer so we don't double-poll.
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
                    self.lastResponse == nil ? self.startRateLimitCycle() : self.stopRateLimitCycle()
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

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            // Slot-machine reels: % and reset spin while the bars dance; hidden
            // parts stay hidden.
            let s = Settings.shared
            self.setTitle(titleParts(s.showPercentage, s.showWave, s.showResetTime, "\(Int.random(in: 0..<100))%",
                                     waveFrame(self.animationFrame), "\(Int.random(in: 0...9)):\(String(format: "%02d", Int.random(in: 0..<60)))"))
            self.animationFrame += 1
        }
    }

    func scheduleAnimationStop() { stopAnimation(after: animationLeft(animationStartedAt, Date())) }

    /// Unless a newer cycle has started by then.
    private func stopAnimation(after seconds: TimeInterval) {
        if seconds <= 0 { return stopAnimation() }
        let gen = animationGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self = self, self.animationGeneration == gen else { return }
            self.stopAnimation()
        }
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationStartedAt = nil
        updateTitle()
    }

    // ── Error animation cycle (frames from error_tick) ──────────────────────

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
        guard let text = errorTick(lastError, Settings.shared.nextAllowedPoll, Date(), rateLimitAnimFrame, marqueeWindowChars) else {
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

    /// 80% / 95% alerts, once per window (alerts in logic/core.pl).
    func checkAndNotifyThresholds(_ f: UsageBucket) {
        let s = Settings.shared
        let (key, fired, due) = alerts(f.utilization, f.resetsAt, s.lastNotifiedResetsAt, Array(s.notifiedThresholds))
        if key != s.lastNotifiedResetsAt { s.lastNotifiedResetsAt = key }
        s.notifiedThresholds = Set(fired)
        for threshold in due {
            let c = UNMutableNotificationContent()
            c.title = alertTitle(threshold)
            c.body = alertBody(threshold)
            c.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "claude-limits.threshold.\(threshold).\(key ?? "")",
                content: c, trigger: nil))
        }
    }

    func formatTopStatusLine() -> String {
        statusLine(lastError, lastUpdated, Settings.shared.nextAllowedPoll, nextPollAt, Clock.now())
    }

    /// One shared width keeps every row flush left and right.
    static let menuRowWidth: CGFloat = 360

    /// Flush-left MenuRowView row; attributedTitle feeds the synthetic dropdown.
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

    /// Label, drawn bar (TabularRowView), value flush-right.
    func tabularItem(label: String, utilization: Double, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label) \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        let view = TabularRowView(label: label, utilization: utilization, value: value,
                                  width: AppDelegate.menuRowWidth)
        view.menuItem = item
        item.view = view
        return item
    }

    /// Label left, value right — no bar (pay-as-you-go etc.).
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

    /// Clickable row; nil target walks the responder chain (NSApp.terminate).
    func actionItem(_ s: String, action: Selector, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: s, action: action, keyEquivalent: "")
        item.target = target
        wrapAsView(item, attr: NSAttributedString(string: s, attributes: [
            .foregroundColor: NSColor.labelColor,
        ]))
        return item
    }

    /// Rows come from menu_rows in logic/core.pl; this only draws them.
    func buildMenu(into menu: NSMenu) {
        for row in menuRows(lastError, lastResponse) {
            switch row {
            case .status:
                let item = plainItem(formatTopStatusLine(), dim: true)
                menu.addItem(item)
                lastUpdatedMenuItem = item
            case .reset:
                guard let f = lastResponse?.fiveHour else { continue }
                let item = plainItem(formatResetLine(f), dim: true)
                menu.addItem(item)
                resetMenuItem = item
            case .separator: menu.addItem(.separator())
            case .header(let text): menu.addItem(sectionHeader(text))
            case .bar(let label, let u, let value): menu.addItem(tabularItem(label: label, utilization: u, value: value))
            case .pair(let label, let value): menu.addItem(payAsYouGoItem(label: label, value: value))
            case .action(let label, .refresh): menu.addItem(actionItem(label, action: #selector(refreshAction), target: self))
            case .action(let label, .openUsage): menu.addItem(actionItem(label, action: #selector(openUsageWeb), target: self))
            case .action(let label, .openSettings): menu.addItem(actionItem(label, action: #selector(openSettings), target: self))
            // target=NSApp — terminate(_:) is on NSApp, not AppDelegate.
            case .action(let label, .quit): menu.addItem(actionItem(label, action: #selector(NSApp.terminate(_:)), target: NSApp))
            }
        }
    }

    @objc func refreshAction() { manualRefresh(fromClick: false) }

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
        // LSUIElement apps stay .accessory; makeKeyAndOrderFront alone doesn't
        // foreground from a menu, so pair it with activate + orderFrontRegardless.
        // (Toggling to .regular and back closes windows shown meanwhile.)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()
    }
}
