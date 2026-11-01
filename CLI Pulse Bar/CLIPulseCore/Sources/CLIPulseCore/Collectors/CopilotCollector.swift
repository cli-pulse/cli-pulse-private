#if os(macOS)
import Foundation

/// Fetches quota snapshots from GitHub Copilot via `copilot_internal/user` API.
///
/// Endpoint: `GET https://api.github.com/copilot_internal/user`
/// Auth: Bearer token from `COPILOT_API_TOKEN` env var or `config.apiKey`.
public struct CopilotCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.copilot

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveToken(config: config) != nil
    }

    /// v1.44 W3: unambiguous — this collector is a pure token lookup, so a
    /// false here always means "no credential", never "no tool".
    ///
    /// Specifically `.missingApiKey`, NOT `.missingCredentials`: Copilot has no
    /// "sign in to the app and we'll pick it up" path, so the generic advice
    /// ("sign in to Copilot in its own app or CLI — no key needed here") is
    /// something the user cannot act on. They must supply `COPILOT_API_TOKEN`.
    /// Copilot is also the clearest example of what W3 measures: 9 sessions
    /// across 3 users produced exactly 1 quota row, because using it requires
    /// hunting down that token unaided.
    public func readiness(config: ProviderConfig) -> CollectorReadiness {
        isAvailable(config: config) ? .ready : .notReady(.missingApiKey)
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        guard let token = resolveToken(config: config) else {
            throw CollectorError.missingCredentials(CredentialProblem("Copilot", .noAPIToken))
        }
        let data = try await fetchUsage(token: token)
        let parsed = try CopilotCollector.parseResponse(data)
        return buildResult(parsed)
    }

    private func resolveToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey, !k.isEmpty { return k }
        if let k = ProcessInfo.processInfo.environment["COPILOT_API_TOKEN"], !k.isEmpty { return k }
        return nil
    }

    private func fetchUsage(token: String) async throws -> Data {
        guard let url = URL(string: "https://api.github.com/copilot_internal/user") else {
            throw CollectorError.invalidURL("copilot_internal/user")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("vscode/1.96.2", forHTTPHeaderField: "Editor-Version")
        request.setValue("copilot-chat/0.26.7", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("GitHubCopilotChat/0.26.7", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        let (data, response) = try await CredentialedURLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CollectorError.httpError(status: (response as? HTTPURLResponse)?.statusCode ?? 0, provider: "Copilot")
        }
        return data
    }

    // MARK: - Parsing

    struct CopilotUsage: Sendable {
        let plan: String
        /// 1.61 (P2): `access_type_sku`. `subscription_ended` comes with no
        /// quota snapshots (upstream CodexBar #4851).
        var accessTypeSKU: String? = nil
        let quotaResetDate: String?
        let premiumEntitlement: Double?
        let premiumRemaining: Double?
        let premiumPercentRemaining: Double?
        let chatEntitlement: Double?
        let chatRemaining: Double?
        let chatPercentRemaining: Double?
    }

    static func parseResponse(_ data: Data) throws -> CopilotUsage {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("Copilot: invalid JSON")
        }
        let plan = json["copilotPlan"] as? String ?? json["copilot_plan"] as? String ?? "unknown"
        let accessTypeSKU = json["access_type_sku"] as? String ?? json["accessTypeSku"] as? String
        let resetDate = json["quotaResetDate"] as? String ?? json["quota_reset_date"] as? String
        let snapshots = json["quotaSnapshots"] as? [String: Any]
            ?? json["quota_snapshots"] as? [String: Any] ?? [:]

        // 1.61: the API names the snapshot `premium_interactions` (upstream
        // CodexBar's CodingKeys); only the camelCase spelling was read, so a
        // real account never got its Premium bar.
        func extract(_ keys: String...) -> (Double?, Double?, Double?) {
            guard let s = keys.lazy.compactMap({ snapshots[$0] as? [String: Any] }).first else { return (nil, nil, nil) }
            return ((s["entitlement"] as? NSNumber)?.doubleValue,
                    (s["remaining"] as? NSNumber)?.doubleValue,
                    (s["percentRemaining"] as? NSNumber)?.doubleValue
                        ?? (s["percent_remaining"] as? NSNumber)?.doubleValue)
        }

        let (pe, pr, pp) = extract("premiumInteractions", "premium_interactions")
        let (ce, cr, cp) = extract("chat")

        return CopilotUsage(plan: plan, accessTypeSKU: accessTypeSKU, quotaResetDate: resetDate,
                            premiumEntitlement: pe, premiumRemaining: pr, premiumPercentRemaining: pp,
                            chatEntitlement: ce, chatRemaining: cr, chatPercentRemaining: cp)
    }

    /// The SKU an account has once its Copilot subscription has ended.
    static let subscriptionEndedSKU = "subscription_ended"

    func buildResult(_ c: CopilotUsage) -> CollectorResult {
        var tiers: [TierDTO] = []

        // 1.61 (P3): the reset as a timestamp every reader parses (a bare date
        // was kept as it came, and nothing downstream read it), and the
        // calendar month it ends as the window.
        let resetDate = CopilotQuotaWindow.parseResetDate(c.quotaResetDate)
        let resetTime = resetDate.map { ISO8601DateFormatter().string(from: $0) } ?? c.quotaResetDate
        let windowMinutes = resetDate.flatMap(CopilotQuotaWindow.minutes(endingAt:))

        if let ent = c.premiumEntitlement, ent > 0 {
            let remaining = c.premiumRemaining ?? (c.premiumPercentRemaining.map { $0 / 100.0 * ent } ?? ent)
            tiers.append(TierDTO(name: "Premium", quota: Int(ent), remaining: Int(remaining),
                                 reset_time: resetTime, windowMinutes: windowMinutes))
        }
        if let ent = c.chatEntitlement, ent > 0 {
            let remaining = c.chatRemaining ?? (c.chatPercentRemaining.map { $0 / 100.0 * ent } ?? ent)
            tiers.append(TierDTO(name: "Chat", quota: Int(ent), remaining: Int(remaining),
                                 reset_time: resetTime, windowMinutes: windowMinutes))
        }

        let overallQuota = c.premiumEntitlement.map { Int($0) }
        let overallRemaining = c.premiumRemaining.map { Int($0) }
        let statusText: String
        if tiers.isEmpty,
           c.accessTypeSKU?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == Self.subscriptionEndedSKU {
            // 1.61 (P2): an ended subscription has no quotas; it read
            // "Operational" with no bars, a confident wrong label.
            statusText = CollectorStatusText.copilotSubscriptionEnded
        } else if let pct = c.premiumPercentRemaining {
            statusText = "\(Int(100 - pct))% used"
        } else {
            statusText = "Operational"
        }

        let usage = ProviderUsage(
            provider: ProviderKind.copilot.rawValue,
            today_usage: overallQuota.map { $0 - (overallRemaining ?? $0) } ?? 0,
            week_usage: overallQuota.map { $0 - (overallRemaining ?? $0) } ?? 0,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: overallQuota, remaining: overallRemaining,
            plan_type: c.plan.capitalized, reset_time: resetTime, tiers: tiers,
            status_text: statusText, trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "GitHub Copilot", category: "ide",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}
#endif
