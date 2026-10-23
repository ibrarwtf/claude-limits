import Foundation

// The response types are generated from logic/core.pl (Logic.swift).

/// Rows for the dropdown's "Weekly limits" section. Falls back to the newer
/// `limits` array when every seven_day* bucket is null. Covered by
/// spec/cases.json (`weeklyRows`).
func weeklyRows(_ r: UsageResponse) -> [(String, UsageBucket)] {
    let legacy: [(String, UsageBucket?)] = [
        ("Overall", r.sevenDay),
        ("Opus", r.sevenDayOpus),
        ("Sonnet", r.sevenDaySonnet),
        ("OAuth apps", r.sevenDayOauthApps),
        ("Cowork", r.sevenDayCowork),
        ("Claude Design", r.sevenDayOmelette),
    ]
    let active = legacy.compactMap { (label, b) in b.map { (label, $0) } }
    if !active.isEmpty { return active }
    return (r.limits ?? []).compactMap { l in
        guard l.group == "weekly", let pct = l.percent else { return nil }
        return (l.scope?.model?.displayName ?? "Overall", UsageBucket(utilization: pct, resetsAt: l.resetsAt))
    }
}
