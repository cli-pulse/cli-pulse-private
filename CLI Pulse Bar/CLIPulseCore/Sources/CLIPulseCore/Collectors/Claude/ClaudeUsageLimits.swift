import Foundation

/// The `limits` array Claude's usage endpoints return beside the flat windows
/// (`five_hour`, `seven_day`, …). Both `/api/oauth/usage` and claude.ai's
/// `/api/organizations/{org}/usage` carry it.
///
/// Claude meters by plan. An Ultra account has no `five_hour` window at all,
/// and besides the all-models week it can have a week scoped to one model:
///
///     "limits": [
///       {"kind": "weekly_all", "group": "weekly", "percent": 40, "resets_at": "…"},
///       {"kind": "weekly_scoped", "group": "weekly", "percent": 55, "resets_at": "…",
///        "scope": {"model": {"id": "…", "display_name": "Fable"}}}
///     ]
///
/// The scoped week can run ahead of the all-models one, so it is the limit the
/// user meets first. Rules follow CodexBar's `ClaudeScopedWeeklyLimitMapper`.
public enum ClaudeUsageLimits {

    /// One model-scoped weekly limit.
    public struct Scoped: Equatable, Sendable {
        /// The vendor's model name, verbatim ("Fable").
        public let modelName: String
        /// Percent used, 0…100.
        public let used: Int
        public let resetsAt: String?

        public init(modelName: String, used: Int, resetsAt: String?) {
            self.modelName = modelName
            self.used = used
            self.resetsAt = resetsAt
        }
    }

    /// At most this many scoped rows: a card is not a list of every model.
    static let maxScoped = 4
    /// A model name longer than this is not a name; the row is skipped.
    static let maxModelNameLength = 40

    /// The model-scoped weekly limits, in the order Claude lists them.
    public static func scopedWeekly(_ json: [String: Any]) -> [Scoped] {
        var seen = Set<String>()
        var result: [Scoped] = []
        for entry in entries(json) {
            guard entry["group"] as? String == "weekly",
                  entry["kind"] as? String == "weekly_scoped",
                  let used = percent(entry["percent"]) else { continue }
            let model = (entry["scope"] as? [String: Any])?["model"] as? [String: Any]
            guard let name = nonEmpty(model?["display_name"] as? String),
                  name.count <= maxModelNameLength,
                  !isAllModels(modelID: model?["id"] as? String, modelName: name) else { continue }
            let identity = slug(nonEmpty(model?["id"] as? String) ?? name)
            guard !identity.isEmpty, seen.insert(identity).inserted else { continue }
            result.append(Scoped(modelName: name, used: used, resetsAt: entry["resets_at"] as? String))
            if result.count == maxScoped { break }
        }
        return result
    }

    /// The all-models week from `limits`, for a body without `seven_day`.
    public static func weeklyAll(_ json: [String: Any]) -> (used: Int, resetsAt: String?)? {
        for entry in entries(json) {
            guard entry["group"] as? String == "weekly",
                  entry["kind"] as? String == "weekly_all",
                  let used = percent(entry["percent"]) else { continue }
            return (used, entry["resets_at"] as? String)
        }
        return nil
    }

    // MARK: - Helpers

    private static func entries(_ json: [String: Any]) -> [[String: Any]] {
        (json["limits"] as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    /// A JSON number (not a boolean), rounded and clamped to 0…100.
    private static func percent(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let raw = number.doubleValue
        guard raw.isFinite else { return nil }
        // Clamp the Double first: `Int(1e20)` traps.
        return Int(min(100, max(0, raw)).rounded())
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func isAllModels(modelID: String?, modelName: String) -> Bool {
        if slug(modelName) == "all-models" { return true }
        guard let id = nonEmpty(modelID) else { return false }
        let idSlug = slug(id)
        return idSlug == "all-models" || idSlug.hasSuffix("-all-models")
    }
}

/// The plan name CLI Pulse shows and prices for Claude.
public enum ClaudePlanType {

    /// `rateLimitTier` is the token's tier ("default_claude_max_20x"); it is
    /// set at sign-in and is not updated when the plan changes, and on an
    /// Ultra account it still reads Max 20x. `planDisplayLabel` is what
    /// `/api/oauth/profile` calls the plan today ("Ultra plan"); when present
    /// it decides the plan, and the tier only adds the Max multiplier.
    public static func resolve(rateLimitTier: String?, planDisplayLabel: String?) -> String {
        let fromTier = fromRateLimitTier(rateLimitTier)
        guard let label = normalizedLabel(planDisplayLabel) else { return fromTier }
        switch ClaudePlan.fromCompatibilityLoginMethod(label) {
        case .max?:
            return fromTier.hasPrefix("Max") ? fromTier : "Max 5x"
        case .ultra?: return "Ultra"
        case .pro?: return "Pro"
        case .team?: return "Team"
        case .enterprise?: return "Enterprise"
        case nil:
            return label
        }
    }

    /// "Ultra plan" → "Ultra". Nil for an empty or implausibly long label.
    static func normalizedLabel(_ raw: String?) -> String? {
        guard var label = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty else { return nil }
        if label.lowercased().hasSuffix(" plan") {
            label = String(label.dropLast(" plan".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !label.isEmpty, label.count <= 40 else { return nil }
        return label
    }

    /// The tier-only reading, unchanged from before labels were read.
    static func fromRateLimitTier(_ rateLimitTier: String?) -> String {
        let tierLower = (rateLimitTier ?? "").lowercased()
        // Match specific Max tiers first (20x before generic max)
        if tierLower.contains("max_20x") || tierLower.contains("max 20x") { return "Max 20x" }
        if tierLower.contains("max_5x") || tierLower.contains("max 5x") { return "Max 5x" }
        if tierLower.contains("max") { return "Max 5x" }  // default Max → 5x
        if tierLower.contains("ultra") { return "Ultra" }
        if tierLower.contains("pro") { return "Pro" }
        if tierLower.contains("team") { return "Team" }
        if tierLower.contains("enterprise") { return "Enterprise" }
        if tierLower.contains("free") { return "Free" }
        return "Unknown"
    }
}
