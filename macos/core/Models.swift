import Foundation

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

/// Entry of the newer `limits` array. As of late 2026 the API returns the
/// seven_day* buckets as null and reports weekly usage only here.
struct LimitModel: Codable {
    let displayName: String?
    enum CodingKeys: String, CodingKey { case displayName = "display_name" }
}

struct LimitScope: Codable {
    let model: LimitModel?
}

struct UsageLimit: Codable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resetsAt: String?
    let scope: LimitScope?
    enum CodingKeys: String, CodingKey {
        case kind, group, percent, scope
        case resetsAt = "resets_at"
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
    let limits: [UsageLimit]?
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case sevenDaySonnet = "seven_day_sonnet"
        case sevenDayCowork = "seven_day_cowork"
        case sevenDayOmelette = "seven_day_omelette"
        case extraUsage = "extra_usage"
        case limits
    }
}

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
