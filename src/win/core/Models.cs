using System.Runtime.Serialization;

namespace ClaudeLimits
{
    [DataContract]
    public sealed class UsageBucket
    {
        // Nullable on the wire so a missing/null utilization decodes instead of
        // failing the whole response; reads as 0.
        [DataMember(Name = "utilization", EmitDefaultValue = false)] public double? UtilizationRaw { get; set; }
        [DataMember(Name = "resets_at", EmitDefaultValue = false)] public string ResetsAt { get; set; }
        public double Utilization => UtilizationRaw ?? 0;
    }

    [DataContract]
    public sealed class ExtraUsage
    {
        [DataMember(Name = "is_enabled", EmitDefaultValue = false)] public bool? IsEnabled { get; set; }
        [DataMember(Name = "monthly_limit", EmitDefaultValue = false)] public double? MonthlyLimit { get; set; }
        [DataMember(Name = "used_credits", EmitDefaultValue = false)] public double? UsedCredits { get; set; }
        [DataMember(Name = "utilization", EmitDefaultValue = false)] public double? Utilization { get; set; }
        [DataMember(Name = "currency", EmitDefaultValue = false)] public string Currency { get; set; }
    }

    [DataContract]
    public sealed class LimitModel
    {
        [DataMember(Name = "display_name", EmitDefaultValue = false)] public string DisplayName { get; set; }
    }

    [DataContract]
    public sealed class LimitScope
    {
        [DataMember(Name = "model", EmitDefaultValue = false)] public LimitModel Model { get; set; }
    }

    /// Entry of the newer `limits` array. As of late 2026 the API returns the
    /// seven_day* buckets as null and reports weekly usage only here.
    [DataContract]
    public sealed class UsageLimit
    {
        [DataMember(Name = "kind", EmitDefaultValue = false)] public string Kind { get; set; }
        [DataMember(Name = "group", EmitDefaultValue = false)] public string Group { get; set; }
        [DataMember(Name = "percent", EmitDefaultValue = false)] public double? Percent { get; set; }
        [DataMember(Name = "resets_at", EmitDefaultValue = false)] public string ResetsAt { get; set; }
        [DataMember(Name = "scope", EmitDefaultValue = false)] public LimitScope Scope { get; set; }
    }

    [DataContract]
    public sealed class UsageResponse
    {
        [DataMember(Name = "limits", EmitDefaultValue = false)] public UsageLimit[] Limits { get; set; }
        [DataMember(Name = "five_hour", EmitDefaultValue = false)] public UsageBucket FiveHour { get; set; }
        [DataMember(Name = "seven_day", EmitDefaultValue = false)] public UsageBucket SevenDay { get; set; }
        [DataMember(Name = "seven_day_oauth_apps", EmitDefaultValue = false)] public UsageBucket SevenDayOauthApps { get; set; }
        [DataMember(Name = "seven_day_opus", EmitDefaultValue = false)] public UsageBucket SevenDayOpus { get; set; }
        [DataMember(Name = "seven_day_sonnet", EmitDefaultValue = false)] public UsageBucket SevenDaySonnet { get; set; }
        [DataMember(Name = "seven_day_cowork", EmitDefaultValue = false)] public UsageBucket SevenDayCowork { get; set; }
        [DataMember(Name = "seven_day_omelette", EmitDefaultValue = false)] public UsageBucket SevenDayOmelette { get; set; }
        [DataMember(Name = "extra_usage", EmitDefaultValue = false)] public ExtraUsage ExtraUsage { get; set; }
    }
}
