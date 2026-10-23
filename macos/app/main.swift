import AppKit

// Before anything touches Settings.shared / UsageHistory.shared.
do {
    try FixtureMode.configure(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write("claude-limits: bad --fixture: \(error)\n".data(using: .utf8)!)
    exit(2)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
