import Foundation

// spec/cases.json runner for the Mac core. windows/tests/Program.cs is the same
// runner for the Windows core — keep the two in step.
//
//   swiftc -o build/spec-macos macos/core/*.swift macos/tests/main.swift
//   build/spec-macos spec/cases.json

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "spec/cases.json"
let root = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
let now = parseISO(root["now"] as? String)!
Clock.pinned = now
UsageHistory.persist = false

var passed = 0, failed = 0

func check(_ name: String, _ got: String?, _ want: String?) {
    if got == want { passed += 1; return }
    failed += 1
    func show(_ s: String?) -> String { s.map { "\"\($0)\"" } ?? "nil" }
    print("FAIL \(name)\n  got:  \(show(got))\n  want: \(show(want))")
}

func cases(_ key: String) -> [[String: Any]] { root[key] as? [[String: Any]] ?? [] }
func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
func str(_ v: Any?) -> String? { v as? String }

let isoFormatter = ISO8601DateFormatter()
func iso(_ d: Date) -> String { isoFormatter.string(from: d) }

func samples(_ v: Any?) -> [HistorySample] {
    (v as? [[Any]] ?? []).map {
        HistorySample(timestamp: now.addingTimeInterval(-num($0[0])!), utilization: num($0[1])!)
    }
}

for c in cases("timeRemaining") {
    let resetsAt = num(c["resetsIn"]).map { iso(now.addingTimeInterval($0)) }
    check("timeRemaining \(c["resetsIn"] ?? "null")", countdown(resetsAt, now), str(c["expect"]))
}
for c in cases("nextAttempt") {
    check("nextAttempt \(c["secs"]!)", nextAttempt(Int(num(c["secs"])!)), str(c["expect"]))
}
for c in cases("relativeTime") {
    check("relativeTime \(c["ago"]!)", relativeTime(now.addingTimeInterval(-num(c["ago"])!), now), str(c["expect"]))
}
for c in cases("isNewerVersion") {
    let got = isNewerVersion(str(c["latest"])!, str(c["current"])!)
    check("isNewerVersion \(c["latest"]!) > \(c["current"]!)", String(got), String((c["expect"] as! NSNumber).boolValue))
}
for c in cases("extractToken") {
    check("extractToken \(str(c["text"])!.prefix(24))", extractTokenFromText(str(c["text"])!), str(c["expect"]))
}
for c in cases("sparkline") {
    check("sparkline: \(c["name"]!)", sparkline(samples(c["samples"]), Int(num(c["width"])!)), str(c["expect"]))
}
for c in cases("resetLine") {
    let resetsAt = num(c["resetsIn"]).map { iso(now.addingTimeInterval($0)) }
    check("resetLine: \(c["name"]!)", resetLine(num(c["utilization"])!, resetsAt, samples(c["samples"]), now), str(c["expect"]))
}
for c in cases("weeklyRows") {
    let data = try! JSONSerialization.data(withJSONObject: c["response"]!)
    let r = try! JSONDecoder().decode(UsageResponse.self, from: data)
    let got = weeklyRows(r).map { "\($0.0)=\(Int(round($0.1.utilization)))" }.joined(separator: ", ")
    check("weeklyRows: \(c["name"]!)", got, str(c["expect"]))
}
for c in cases("rollover") {
    UsageHistory.shared.replaceSamples([])
    for step in c["steps"] as! [[String: Any]] {
        Clock.pinned = now.addingTimeInterval(num(step["t"])!)
        UsageHistory.shared.append(utilization: num(step["u"])!, resetsAt: iso(now.addingTimeInterval(num(step["r"])!)))
    }
    Clock.pinned = now
    check("rollover: \(c["name"]!)", String(UsageHistory.shared.samples.count), String(Int(num(c["expectCount"])!)))
}

print("macos spec: \(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
