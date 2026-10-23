import Foundation

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
    return rawToken(text)
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
    // Login shell so the user's PATH / ssh config is available to custom token
    // commands (the documented `ssh devbox '...'` case).
    task.arguments = ["-l", "-c", cmd]
    let outPipe = Pipe(); let errPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = errPipe
    try task.run()

    // Drain both pipes concurrently with the wait — NOT after it. Reading only
    // once the process has exited deadlocks if the child writes more than the
    // ~64KB pipe buffer (a chatty `-l` login profile can): it blocks in write(),
    // never exits, and we'd spuriously time out.
    var outData = Data(); var errData = Data()
    let ioGroup = DispatchGroup()
    ioGroup.enter()
    DispatchQueue.global().async {
        outData = outPipe.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave()
    }
    ioGroup.enter()
    DispatchQueue.global().async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile(); ioGroup.leave()
    }

    let waitGroup = DispatchGroup()
    waitGroup.enter()
    DispatchQueue.global().async { task.waitUntilExit(); waitGroup.leave() }
    if waitGroup.wait(timeout: .now() + timeout) == .timedOut {
        // Escalate SIGTERM → SIGKILL. A child that ignores SIGTERM (custom trap,
        // or parked in a hung network read like a stuck ssh) would otherwise keep
        // waitUntilExit parked forever, leaking the thread and pipe FDs for our
        // whole lifetime — and runShell runs on every poll.
        task.terminate()
        kill(task.processIdentifier, SIGKILL)
        throw AppError.commandFailed("timed out after \(Int(timeout))s")
    }
    // Process exited → the readers hit EOF and finish; join before reading.
    ioGroup.wait()
    let out = String(data: outData, encoding: .utf8) ?? ""
    if task.terminationStatus != 0 {
        let err = String(data: errData, encoding: .utf8) ?? ""
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

/// Read Claude Code's credentials from the macOS Keychain. This is the default
/// storage on stock Mac installs — `knownCredentialPaths` are only used in
/// Docker/Linux/WSL/custom setups. First call triggers a system Always-Allow
/// prompt; subsequent calls from the same signed bundle are silent.
func loadTokenFromKeychain() throws -> String {
    let output = try runShell("security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null")
    if let tok = extractTokenFromText(output) { return tok }
    throw AppError.tokenNotFound
}

/// Track which source produced the most recent token so we only log on change —
/// keeps the log free of repetition while still recording fall-through events.
private var lastLoggedTokenSource: String?
private func logTokenSourceOnce(_ source: String) {
    if lastLoggedTokenSource != source {
        NSLog("claude-limits token from: \(source)")
        lastLoggedTokenSource = source
    }
}

func loadAccessToken() throws -> String {
    switch Settings.shared.tokenSource {
    case .auto:
        if let tok = try? loadTokenFromKeychain() {
            logTokenSourceOnce("keychain (auto)")
            return tok
        }
        for path in knownCredentialPaths {
            if let tok = try? loadTokenFromFile(path) {
                logTokenSourceOnce("file \(path) (auto)")
                return tok
            }
        }
        throw AppError.tokenNotFound
    case .file:
        let path = Settings.shared.customFilePath
        if path.isEmpty { throw AppError.tokenNotFound }
        let tok = try loadTokenFromFile(path)
        logTokenSourceOnce("file \(path) (custom)")
        return tok
    case .shell:
        let tok = try loadTokenFromShell(Settings.shared.customShellCommand)
        logTokenSourceOnce("shell command (custom)")
        return tok
    }
}
