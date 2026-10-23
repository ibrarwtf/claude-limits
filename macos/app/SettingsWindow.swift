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

/// Utilization history: coral line, soft fill; empty below 2 samples (never faked).
final class TopWaveView: NSView {
    override var isFlipped: Bool { false } // Cocoa-default Y-up

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        let samples = waveValues(UsageHistory.shared.samples)   // logic/core.pl
        guard !samples.isEmpty else { return }

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
    /// The Display toggles in order, each bound to the setting it writes.
    static let toggles: [(label: String, key: ReferenceWritableKeyPath<Settings, Bool>)] = [
        ("Percentage", \.showPercentage), ("Burn-rate wave", \.showWave),
        ("Reset countdown", \.showResetTime), ("Open at login", \.launchAtStartup),
    ]
    var switches: [NSSwitch] = []
    var subTogglesStack: NSStackView!
    var mockContainer: NSView!
    var mockPct: NSTextField!
    var mockBars: NSTextField!
    var mockReset: NSTextField!
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
        switches = Self.toggles.map { _ in makeSwitch() }
        subTogglesStack = NSStackView(views: zip(Self.toggles, switches).map { makeToggleRow($0.0.label, sw: $0.1) })
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
        // "made by ibr" is a borderless NSButton, not a link NSTextField: that one is
        // an NSTextView underneath, which cacheDisplay (snapshots) won't paint.
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

        // Explicit constraints centre `by`; NSStackView .fill wouldn't.
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
        for (t, sw) in zip(Self.toggles, switches) { sw.state = Settings.shared[keyPath: t.key] ? .on : .off }
        applyMockToToggles()
        modeChanged()
        applyUpdateButtonState()
    }

    // ── Section helpers ──────────────────────────────────────────────────────

    private func sectionDivider() -> NSView {
        // icon column 150 + spacing 18 + controls 460, so the rule stops at the toggles.
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
        // credentials.json glyph: bordered rect with a status dot.
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

    /// nil = not yet probed (gray); true / false = token reachable / failed (green / red pulse).
    private func setCredentialsDot(_ ok: Bool?) {
        guard let layer = credentialsDot?.layer else { return }
        layer.removeAnimation(forKey: "pulse")
        layer.opacity = 1
        guard let ok = ok else { layer.backgroundColor = NSColor.secondaryLabelColor.cgColor; return }
        layer.backgroundColor = (ok ? NSColor.systemGreen : NSColor.systemRed).cgColor
        let anim = CABasicAnimation(keyPath: "opacity")
        anim.fromValue = 1.0
        anim.toValue = 0.25
        anim.duration = 1.4
        anim.autoreverses = true
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(anim, forKey: "pulse")
    }

    /// Updates the dot on open; see dot_on_open in logic/core.pl.
    private func refreshCredentialsDot() {
        guard let d = NSApp.delegate as? AppDelegate else { return }
        switch dotOnOpen(d.lastResponse != nil, Settings.shared.lastSuccessfulPoll, d.isRefreshing,
                         Settings.shared.nextAllowedPoll, d.lastManualClickAt, Date()) {
        case .connected: setCredentialsDot(true)
        case .unverified: setCredentialsDot(nil)
        case .probe:
            d.lastManualClickAt = Date()
            fetchUsage { [weak self] r in
                DispatchQueue.main.async {
                    if case .success = r { self?.setCredentialsDot(true) } else { self?.setCredentialsDot(false) }
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
        // Dark-pill mock of the menu-bar widget; toggles show/hide its parts.
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

    /// Mirror toggles into the mock; hidden stack subviews drop out so it narrows.
    private func applyMockToToggles() {
        guard mockContainer != nil else { return }
        mockPct.isHidden   = switches[0].state != .on
        mockBars.isHidden  = switches[1].state != .on
        mockReset.isHidden = switches[2].state != .on
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

    /// "[label] ...... [switch]" with a flexible spacer so switches align.
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
        hintLabel.stringValue = sourceHint(mode, false, knownCredentialPaths.first!)
        fileRow.isHidden = mode != .file
        shellRow.isHidden = mode != .shell
    }

    func collect() {
        Settings.shared.tokenSource = TokenSource(rawValue: modePopup.indexOfSelectedItem) ?? .auto
        Settings.shared.customFilePath = fileField.stringValue
        Settings.shared.customShellCommand = shellField.stringValue
        for (t, sw) in zip(Self.toggles, switches) { Settings.shared[keyPath: t.key] = sw.state == .on }
    }

    @objc func checkForUpdates() {
        statusLabel.stringValue = "Checking for updates…"
        statusLabel.textColor = .secondaryLabelColor
        (NSApp.delegate as? AppDelegate)?.checkForLatestRelease { [weak self] latest, err in
            guard let self = self else { return }
            let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
            self.statusLabel.stringValue = updateStatus(latest, err?.localizedDescription, v)
            self.statusLabel.textColor = err != nil ? .secondaryLabelColor : latest != nil ? .systemOrange : .labelColor
            if err == nil { self.applyUpdateButtonState() }
        }
    }

    /// A known newer version turns "Check for updates" into "Update to vX".
    private func applyUpdateButtonState() {
        guard updateBtn != nil else { return }
        let latest = (NSApp.delegate as? AppDelegate)?.latestVersionAvailable
        updateBtn.title = updateButton(latest)
        updateBtn.action = latest == nil ? #selector(checkForUpdates) : #selector(performUpdate)
    }

    /// Runs `brew upgrade` DETACHED (waits for us to exit) because the cask's
    /// `uninstall quit:` kills us mid-upgrade — a child brew would die too. The
    /// trailing `open` brings us back even if brew no-ops or fails. Dev installs
    /// (~/Applications, no cask) get the releases page instead.
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
        statusLabel.stringValue = updatingStatus(latest)
        statusLabel.textColor = .secondaryLabelColor
        updateBtn.isEnabled = false
        // Posted ~0.7s before quitting so it delivers while the icon is gone.
        (NSApp.delegate as? AppDelegate)?.notifyUpdating(to: latest)
        // Watch our pid with `kill -0`, not pgrep -f: the watcher's own argv holds
        // the pattern, so it would self-match forever. `open` only activates an
        // already-running app, never launches a duplicate.
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
        // No diagnostic hits during an active 429 window.
        if let until = Settings.shared.nextAllowedPoll, until > Date() {
            statusLabel.stringValue = waitStatus(max(0, Int(until.timeIntervalSinceNow)))
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
                    self.statusLabel.stringValue = testStatus(u.fiveHour?.utilization)
                    self.statusLabel.textColor = .labelColor
                    self.setCredentialsDot(true)
                case .failure(let e):
                    // Feed the 429 into the shared back-off so testing can't reset the cooldown.
                    if case .rateLimited(let retry) = e {
                        (NSApp.delegate as? AppDelegate)?.recordRateLimit(retry)
                    }
                    self.statusLabel.stringValue = friendlyMessage(e)
                    self.statusLabel.textColor = .labelColor
                    self.setCredentialsDot(false)
                }
            }
        }
    }
}
