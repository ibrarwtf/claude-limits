import AppKit

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

/// Historic utilization plot in the Settings window — coral line with soft
/// fill below. Real data only; leaves the strip empty when there's < 2
/// samples instead of faking a curve.
final class TopWaveView: NSView {
    /// Three repetitions visually echoes the rolling-window concept.
    private let tileCount = 3
    private let smoothWindow = 3

    override var isFlipped: Bool { false } // Cocoa-default Y-up

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        // Treat error sentinels (utilization < 0) as 0 — flat dip in the line.
        let raw = UsageHistory.shared.samples.map {
            $0.utilization < 0 ? 0.0 : $0.utilization
        }
        guard raw.count >= 2 else { return }
        let smoothed = movingAverage(raw, window: smoothWindow)
        // Tile the smoothed pattern so the rolling-window cadence reads even
        // with one session of data.
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

        let linePath = NSBezierPath()
        linePath.lineWidth = 1.4
        linePath.lineJoinStyle = .round
        linePath.move(to: points[0])
        for p in points.dropFirst() { linePath.line(to: p) }
        lineColor.setStroke()
        linePath.stroke()
    }

    /// Centred moving-average smoothing. Output length == input length.
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
    var statusLabel: NSTextField!
    var hintLabel: NSTextField!
    var fileRow: NSView!
    var shellRow: NSView!
    var pctSwitch: NSSwitch!
    var waveSwitch: NSSwitch!
    var resetSwitch: NSSwitch!
    var subTogglesStack: NSStackView!
    var mockContainer: NSView!
    var mockPct: NSTextField!
    var mockBars: NSTextField!
    var mockReset: NSTextField!
    var launchSwitch: NSSwitch!
    var updateBtn: NSButton!     // flips between "Check for updates" and "Update to vX"
    var credentialsDot: NSView?  // green-pulsing when token is reachable

    override func loadView() {
        let WIDTH: CGFloat = 720
        let HEIGHT: CGFloat = 660
        let container = NSView(frame: NSRect(x: 0, y: 0, width: WIDTH, height: HEIGHT))

        let wave = TopWaveView(frame: NSRect(x: 0, y: HEIGHT - 56, width: WIDTH, height: 56))
        wave.autoresizingMask = [.width, .minYMargin]
        container.addSubview(wave)

        // ── Token source ────────────────────────────────────────────────────
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

        let tokenRow = makeRow("Token source", control: modePopup)

        let tokenControls = NSStackView(views: [tokenRow, hintLabel, fileRow, shellRow])
        tokenControls.orientation = .vertical
        tokenControls.alignment = .leading
        tokenControls.spacing = 8
        let tokenSection = makeSection(iconView: makeKeyArt("credentials.json"),
                                       controls: tokenControls)

        // ── Menu bar + General (merged) ─────────────────────────────────────
        pctSwitch    = makeSwitch()
        waveSwitch   = makeSwitch()
        resetSwitch  = makeSwitch()
        launchSwitch = makeSwitch()
        subTogglesStack = NSStackView(views: [
            makeToggleRow("Percentage", sw: pctSwitch),
            makeToggleRow("Burn-rate wave", sw: waveSwitch),
            makeToggleRow("Reset countdown", sw: resetSwitch),
            makeToggleRow("Open at login", sw: launchSwitch),
        ])
        subTogglesStack.orientation = .vertical
        subTogglesStack.alignment = .leading
        subTogglesStack.spacing = 4

        updateBtn = NSButton(title: "Check for updates", target: self, action: #selector(checkForUpdates))
        updateBtn.bezelStyle = .roundRect
        let updateRow = NSStackView(views: [updateBtn])
        updateRow.orientation = .horizontal

        statusLabel = NSTextField(wrappingLabelWithString: " ")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.preferredMaxLayoutWidth = 460

        let menuControls = NSStackView(views: [subTogglesStack, updateRow, statusLabel])
        menuControls.orientation = .vertical
        menuControls.alignment = .leading
        menuControls.spacing = 8
        let menuSection = makeSection(iconView: makeMenubarArt(), controls: menuControls)

        let sectionStack = NSStackView(views: [
            tokenSection, sectionDivider(), menuSection,
        ])
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 14
        sectionStack.translatesAutoresizingMaskIntoConstraints = false

        // ── Action buttons row [Test fetch] [Save] ──────────────────────────
        let testBtn = NSButton(title: "Test fetch", target: self, action: #selector(testFetch))
        testBtn.bezelStyle = .roundRect
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
        // "made by ibr" — clickable link to the maintainer's GitHub.
        // Rendered as a borderless NSButton (not an NSTextField) so it paints
        // correctly into the offscreen bitmap context used for snapshots —
        // NSTextField's selectable+attributedString-link trick uses NSTextView
        // under the hood, which doesn't honour cacheDisplay.
        let byAttr = NSMutableAttributedString(string: "made by ibr")
        byAttr.addAttributes([
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
        ], range: NSRange(location: 0, length: byAttr.length))
        let by = NSButton(title: "", target: self, action: #selector(openMaintainerGitHub))
        by.attributedTitle = byAttr
        by.isBordered = false
        by.bezelStyle = .inline
        by.setButtonType(.momentaryChange)
        by.contentTintColor = nil  // let attributedTitle drive color

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        let ver = NSTextField(labelWithString: "v\(version)")
        ver.textColor = .tertiaryLabelColor
        ver.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Dead-centre `by` in the container; `ver` rides the trailing edge.
        // (NSStackView .fill distribution wasn't centring the text inside the
        // expanded NSTextField — explicit constraints are simpler than fighting
        // NSStackView's intrinsic-size logic.)
        by.translatesAutoresizingMaskIntoConstraints = false
        ver.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(sectionStack)
        container.addSubview(buttonStack)
        container.addSubview(by)
        container.addSubview(ver)

        NSLayoutConstraint.activate([
            sectionStack.topAnchor.constraint(equalTo: wave.bottomAnchor, constant: 12),
            sectionStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            sectionStack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),

            buttonStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            buttonStack.bottomAnchor.constraint(equalTo: by.topAnchor, constant: -12),

            by.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            by.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),

            ver.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            ver.bottomAnchor.constraint(equalTo: by.bottomAnchor),
        ])
        view = container

        modePopup.selectItem(at: Settings.shared.tokenSource.rawValue)
        fileField.stringValue = Settings.shared.customFilePath
        shellField.stringValue = Settings.shared.customShellCommand
        pctSwitch.state    = Settings.shared.showPercentage ? .on : .off
        waveSwitch.state   = Settings.shared.showWave       ? .on : .off
        resetSwitch.state  = Settings.shared.showResetTime  ? .on : .off
        launchSwitch.state = Settings.shared.launchAtStartup ? .on : .off
        applyMockToToggles()
        modeChanged()
        applyUpdateButtonState()
    }

    // ── Section helpers ──────────────────────────────────────────────────────

    private func sectionDivider() -> NSView {
        // Width matches the section content: icon column (150) + spacing (18)
        // + controls (460) = 628. Stops the divider from overshooting past
        // the toggle column.
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 628).isActive = true
        return box
    }

    private func makeSection(iconView: NSView, controls: NSStackView) -> NSView {
        // 150px icon column on the left, controls on the right.
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
        // Minimal credentials.json glyph: bordered rect with a dot indicator.
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
        credentialsDot = dot
        return v
    }

    /// Three states: gray = unverified (initial / not yet probed),
    /// green-pulsing = token reachable, red-pulsing = token verified failed.
    private enum CredentialsState { case unverified, connected, disconnected }

    private func setCredentialsState(_ state: CredentialsState) {
        guard let dot = credentialsDot, let layer = dot.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        switch state {
        case .unverified:
            layer.opacity = 1
            layer.backgroundColor = NSColor.secondaryLabelColor.cgColor
        case .connected, .disconnected:
            layer.backgroundColor = (state == .connected
                ? NSColor.systemGreen
                : NSColor.systemRed).cgColor
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = 1.0
            anim.toValue = 0.25
            anim.duration = 1.4
            anim.autoreverses = true
            anim.repeatCount = .infinity
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(anim, forKey: "pulse")
        }
    }

    private func setCredentialsDotConnected(_ connected: Bool) {
        setCredentialsState(connected ? .connected : .disconnected)
    }

    /// Quick token-reachability probe; updates the dot. Settings-open reuses
    /// recent app state so merely opening the window doesn't burn a usage call.
    private func refreshCredentialsDot() {
        if let delegate = NSApp.delegate as? AppDelegate {
            if delegate.lastResponse != nil {
                setCredentialsDotConnected(true)
                return
            }
            if let last = Settings.shared.lastSuccessfulPoll,
               Date().timeIntervalSince(last) < pollIntervalSeconds {
                setCredentialsDotConnected(true)
                return
            }
            if delegate.isRefreshing {
                setCredentialsState(.unverified)
                return
            }
            if let until = Settings.shared.nextAllowedPoll, until > Date() {
                setCredentialsState(.unverified)
                return
            }
            // Throttle the probe so reopening Settings in a tight loop can't
            // fire an ungated fetch per reopen (cold-start / prior non-429
            // error state, where nothing above short-circuits).
            if let last = delegate.lastManualClickAt,
               Date().timeIntervalSince(last) < delegate.manualClickCooldown {
                setCredentialsState(.unverified)
                return
            }
            delegate.lastManualClickAt = Date()
        }
        fetchUsage { [weak self] r in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch r {
                case .success: self.setCredentialsDotConnected(true)
                case .failure: self.setCredentialsDotConnected(false)
                }
            }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshCredentialsDot()
        applyUpdateButtonState()
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

    /// Mirror toggle state into the live preview mock. NSStackView removes
    /// hidden subviews from layout so the pill naturally narrows.
    private func applyMockToToggles() {
        guard mockContainer != nil else { return }
        mockPct.isHidden   = pctSwitch.state   != .on
        mockBars.isHidden  = waveSwitch.state  != .on
        mockReset.isHidden = resetSwitch.state != .on
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

    private func makeRow(_ label: String, control: NSView) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
        let row = NSStackView(views: [lbl, control])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        return row
    }

    private func makeSwitch() -> NSSwitch {
        let sw = NSSwitch()
        sw.target = self
        sw.action = #selector(toggleChanged(_:))
        return sw
    }

    /// Horizontal "[label] ........... [switch]" with a flexible spacer so
    /// switches stack vertically aligned. systemFontSize for accessibility.
    private func makeToggleRow(_ label: String, sw: NSSwitch) -> NSView {
        let lbl = NSTextField(labelWithString: label)
        lbl.font = .systemFont(ofSize: NSFont.systemFontSize)
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
        return row
    }

    @objc func toggleChanged(_ sender: NSSwitch) {
        applyMockToToggles()
    }

    @objc func modeChanged() {
        let mode = TokenSource(rawValue: modePopup.indexOfSelectedItem) ?? .auto
        switch mode {
        case .auto:
            hintLabel.stringValue = "We check the macOS Keychain (where Claude Code stores credentials by default), then fall back to common file paths like " + knownCredentialPaths.first! + "."
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
        Settings.shared.showPercentage = pctSwitch.state == .on
        Settings.shared.showWave       = waveSwitch.state == .on
        Settings.shared.showResetTime  = resetSwitch.state == .on
        Settings.shared.launchAtStartup = launchSwitch.state == .on
    }

    @objc func checkForUpdates() {
        statusLabel.stringValue = "Checking for updates…"
        statusLabel.textColor = .secondaryLabelColor
        (NSApp.delegate as? AppDelegate)?.checkForLatestRelease { [weak self] latest, err in
            guard let self = self else { return }
            if let err = err {
                self.statusLabel.stringValue = "Couldn't reach GitHub: \(err.localizedDescription)"
                self.statusLabel.textColor = .secondaryLabelColor
                return
            }
            if let latest = latest {
                self.statusLabel.stringValue = "Update \(latest) available — click “Update to \(latest)”."
                self.statusLabel.textColor = NSColor.systemOrange
            } else {
                let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
                self.statusLabel.stringValue = "You're on the latest version (v\(v))."
                self.statusLabel.textColor = .labelColor
            }
            self.applyUpdateButtonState()
        }
    }

    /// Reflect known update availability on the action button: a pending update
    /// turns "Check for updates" into "Update to vX" (which performs it). Driven
    /// by the AppDelegate's cached latestVersionAvailable (set at launch + daily).
    private func applyUpdateButtonState() {
        guard updateBtn != nil else { return }
        if let latest = (NSApp.delegate as? AppDelegate)?.latestVersionAvailable {
            updateBtn.title = "Update to \(latest)"
            updateBtn.action = #selector(performUpdate)
        } else {
            updateBtn.title = "Check for updates"
            updateBtn.action = #selector(checkForUpdates)
        }
    }

    /// Simplest self-update for a Homebrew-distributed app: run `brew upgrade`.
    /// The work is DETACHED — a subshell that waits for this process to exit,
    /// then upgrades — because the cask's own `uninstall quit:` stanza force-
    /// quits us mid-upgrade; if brew were our child it'd die with us. The cask
    /// postflight re-opens the freshly installed app; the trailing `open`
    /// guarantees the app comes back even if brew was a no-op or failed, so we
    /// never leave the user with a quit app. Dev installs (~/Applications, not a
    /// brew cask) can't `brew upgrade`, so they're sent to the releases page.
    @objc func performUpdate() {
        guard let latest = (NSApp.delegate as? AppDelegate)?.latestVersionAvailable else {
            checkForUpdates(); return
        }
        let brewBundle = "/Applications/claude-limits.app"
        guard Bundle.main.bundlePath == brewBundle else {
            statusLabel.stringValue = "Update \(latest) available — re-run install.sh or download from GitHub."
            statusLabel.textColor = NSColor.systemOrange
            if let url = URL(string: "https://github.com/ibrarwtf/claude-limits/releases/latest") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        statusLabel.stringValue = "Updating to \(latest)… the app will relaunch when done."
        statusLabel.textColor = .secondaryLabelColor
        updateBtn.isEnabled = false
        // Breadcrumb during the brief gap where the app quits and the menu-bar
        // icon disappears while brew swaps the bundle. Posted ~0.7s before we
        // terminate, so it has time to deliver.
        (NSApp.delegate as? AppDelegate)?.notifyUpdating(to: latest)
        // Watch THIS pid, not a pgrep pattern. The watcher carries our pattern
        // string in its own argv, so `pgrep -f '/Contents/MacOS/claude-limits'`
        // would self-match and the loop would never exit (brew never runs).
        // `kill -0 <pid>` polls liveness without that trap. After we quit, brew
        // upgrades and the cask postflight reopens us; the trailing `open`
        // covers a brew no-op/failure — it just activates the app if it's
        // already running, never launches a duplicate.
        let pid = getpid()
        let cmd = """
        ( while kill -0 \(pid) 2>/dev/null; do sleep 0.5; done; \
          brew upgrade --cask claude-limits >/tmp/claude-limits-update.log 2>&1; \
          sleep 1; \
          open '\(brewBundle)' ) &
        """
        let task = Process()
        task.launchPath = "/bin/zsh"
        task.arguments = ["-lc", cmd]
        do {
            try task.run()
        } catch {
            statusLabel.stringValue = "Couldn't start update. Run `brew upgrade --cask claude-limits` manually."
            statusLabel.textColor = NSColor.systemOrange
            updateBtn.isEnabled = true
            return
        }
        // Give the detached watcher a beat to spawn, then quit so brew can
        // replace the bundle (LaunchAgent KeepAlive won't restart a clean exit).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            NSApp.terminate(nil)
        }
    }

    @objc func openMaintainerGitHub() {
        if let url = URL(string: "https://github.com/ibrarwtf") {
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
        // Respect the rate-limit cooldown — a diagnostic button shouldn't hit
        // Anthropic during an active 429 window.
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            statusLabel.stringValue = "Rate limited — wait \(max(0, Int(until.timeIntervalSinceNow)))s before testing again."
            statusLabel.textColor = .secondaryLabelColor
            return
        }
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
                    self.setCredentialsDotConnected(true)
                case .failure(let e):
                    // Feed a 429 into the shared back-off so a test fetch can't
                    // silently reset Anthropic's cooldown while the poller waits.
                    if case .rateLimited(let retry) = e {
                        (NSApp.delegate as? AppDelegate)?.recordRateLimit(retryAfter: retry)
                    }
                    self.statusLabel.stringValue = "\(e.friendlyMessage)"
                    self.statusLabel.textColor = .labelColor
                    self.setCredentialsDotConnected(false)
                }
            }
        }
    }
}
