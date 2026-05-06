import AppKit
import Foundation

// All snapshot capture lives here — URL-scheme handler + view-to-PNG renderers.
// Triggered by scripts/snapshot.sh; no Screen Recording grant needed because we
// render our own NSViews into bitmaps via cacheDisplay (and a synthetic redraw
// for NSStatusItem.button + NSMenu, neither of which respects cacheDisplay).

extension AppDelegate {

    /// URL-scheme handler. Used by scripts/snapshot.sh to capture the app's
    /// own UI silently — no Terminal, no popups, no Screen Recording grant.
    /// URLs:
    ///   claude-limits://snapshot/menubar?dest=/abs/path/to/snapshots
    ///   claude-limits://snapshot/dropdown?dest=/abs/path/to/snapshots
    ///   claude-limits://snapshot/settings?dest=/abs/path/to/snapshots
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.host == "snapshot" {
                let kind = url.path.replacingOccurrences(of: "/", with: "")
                let dest = url.queryParam("dest") ?? defaultSnapshotsDir()
                captureToFile(kind: kind, dest: dest)
            }
        }
    }

    fileprivate func defaultSnapshotsDir() -> String {
        ("~/Library/Application Support/claude-limits/snapshots" as NSString).expandingTildeInPath
    }

    /// Capture our own UI to a PNG. NSStatusItem.button is special: it's a
    /// system-managed view that ignores cacheDisplay, so renderMenubarPNG
    /// re-draws its attributedTitle onto a flat bar manually.
    fileprivate func captureToFile(kind: String, dest: String) {
        for mode in ["light", "dark"] {
            let dark = (mode == "dark")
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let png: Data?
            switch kind {
            case "menubar":
                png = renderMenubarPNG(dark: dark)
            case "settings":
                let vc = SettingsViewController()
                vc.onSave = {}
                vc.loadView()
                let v = vc.view
                v.appearance = appearance
                // Layer-backed bg fill — without a window the view has no
                // intrinsic background colour, so dark-mode label text would
                // be invisible (white-on-white).
                v.wantsLayer = true
                v.layer?.backgroundColor = (dark
                    ? NSColor(white: 0.18, alpha: 1.0).cgColor
                    : NSColor(white: 0.95, alpha: 1.0).cgColor)
                v.layoutSubtreeIfNeeded()
                png = renderViewPNG(v, with: appearance)
            case "dropdown":
                let menu = NSMenu()
                menu.delegate = self
                buildMenu(into: menu)
                png = renderDropdownPNG(items: menu.items, dark: dark, appearance: appearance)
            default:
                return
            }
            guard let data = png else { continue }
            try? FileManager.default.createDirectory(atPath: dest, withIntermediateDirectories: true)
            try? data.write(to: URL(fileURLWithPath: "\(dest)/\(kind)-\(mode).png"))
        }
    }

    /// cacheDisplay with the given appearance set as current drawing appearance,
    /// so dynamic NSColors (labelColor, secondaryLabelColor, etc.) resolve
    /// correctly for the requested mode.
    fileprivate func renderViewPNG(_ v: NSView, with appearance: NSAppearance) -> Data? {
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        return rep.representation(using: .png, properties: [:])
    }

    /// Render the dropdown's menu items into an NSMenu-style image. Synthetic
    /// (not a real NSMenu screenshot — those are system-managed and need
    /// Screen Recording), but content-faithful since we iterate the same
    /// NSMenuItem array buildMenu() builds.
    fileprivate func renderDropdownPNG(items: [NSMenuItem], dark: Bool, appearance: NSAppearance) -> Data? {
        let lineHeight = MenuRowView.rowHeight
        let separatorH: CGFloat = 11
        let padTop: CGFloat = 6, padBottom: CGFloat = 6
        let padLeft = MenuRowView.leftPad, padRight = MenuRowView.rightPad
        // Match the real menu row width so tab-stop columns land in the same
        // pixel positions, keeping synthetic and live menu visually identical.
        let width = AppDelegate.menuRowWidth

        var contentH: CGFloat = padTop + padBottom
        for item in items {
            if item.isSeparatorItem {
                contentH += separatorH
            } else if let v = item.view {
                contentH += v.bounds.height
            } else {
                contentH += lineHeight
            }
        }

        let canvas = NSSize(width: width, height: contentH)
        let img = NSImage(size: canvas)
        img.lockFocus()

        appearance.performAsCurrentDrawingAppearance {
            if dark {
                NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.20, alpha: 0.98).setFill()
            } else {
                NSColor(calibratedRed: 0.97, green: 0.97, blue: 0.97, alpha: 0.99).setFill()
            }
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: canvas),
                         xRadius: 8, yRadius: 8).fill()

            var y = canvas.height - padTop
            let sepColor = dark ? NSColor(white: 1.0, alpha: 0.10) : NSColor(white: 0.0, alpha: 0.12)
            for item in items {
                if item.isSeparatorItem {
                    sepColor.setStroke()
                    let path = NSBezierPath()
                    path.lineWidth = 1
                    let sepY = y - separatorH / 2
                    path.move(to: NSPoint(x: padLeft, y: sepY))
                    path.line(to: NSPoint(x: width - padRight, y: sepY))
                    path.stroke()
                    y -= separatorH
                } else if let tab = item.view as? TabularRowView {
                    // Draw the tabular row directly — same draw code the live
                    // menu uses, no cacheDisplay (offscreen contexts ignore the
                    // appearance override we set above for some items).
                    let h = tab.bounds.height
                    TabularRowView.paint(
                        label: tab.label, utilization: tab.utilization, value: tab.value,
                        bounds: NSRect(x: 0, y: 0, width: tab.bounds.width, height: h),
                        isHighlighted: false,
                        origin: NSPoint(x: 0, y: y - h))
                    y -= h
                } else {
                    // Plain text item — draw the attributed title (font is forced
                    // to NSFont.menuFont so live + synthetic match exactly).
                    let base = item.attributedTitle ?? NSAttributedString(string: item.title)
                    let mut = NSMutableAttributedString(attributedString: base)
                    mut.addAttribute(.font, value: NSFont.menuFont(ofSize: 0),
                        range: NSRange(location: 0, length: mut.length))
                    let drawY = y - lineHeight + 5
                    mut.draw(at: NSPoint(x: padLeft, y: drawY))
                    y -= lineHeight
                }
            }
        }

        img.unlockFocus()

        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    fileprivate func renderMenubarPNG(dark: Bool) -> Data? {
        guard let button = statusItem.button else { return nil }
        let title = (button.attributedTitle.length > 0)
            ? NSMutableAttributedString(attributedString: button.attributedTitle)
            : NSMutableAttributedString(string: button.title, attributes: [
                .font: NSFont.menuBarFont(ofSize: NSFont.systemFontSize)
            ])
        // Force a contrasting foreground colour — system colour from the live
        // status item won't match our flat-bar background.
        title.addAttribute(.foregroundColor,
                           value: dark ? NSColor.white : NSColor.black,
                           range: NSRange(location: 0, length: title.length))
        let pad: CGFloat = 8
        let titleSize = title.size()
        let w = ceil(titleSize.width) + pad * 2
        let h = ceil(titleSize.height) + pad * 2
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        if dark {
            NSColor(calibratedRed: 0.13, green: 0.13, blue: 0.13, alpha: 1.0).setFill()
        } else {
            NSColor(calibratedRed: 0.95, green: 0.95, blue: 0.95, alpha: 1.0).setFill()
        }
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        title.draw(at: NSPoint(x: pad, y: pad))
        img.unlockFocus()
        guard let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
