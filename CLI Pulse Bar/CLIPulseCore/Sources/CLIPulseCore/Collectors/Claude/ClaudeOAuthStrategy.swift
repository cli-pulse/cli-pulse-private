#if os(macOS)
import Foundation
import Security

/// Fetches Claude usage via the Anthropic OAuth usage API.
///
/// Endpoint: `GET https://api.anthropic.com/api/oauth/usage`
/// Uses tokens from: env var, config apiKey, ~/.claude/.credentials.json, or Keychain.
///
/// Rate-limit backoff: after a 429 response, this strategy records a
/// 15-minute cooldown keyed by SHA256 token fingerprint via
/// `ClaudeOAuthBackoffState.shared`. During the cooldown window
/// `fetch()` short-circuits with `ClaudeStrategyError.rateLimitBackoff`
/// (which `shouldFallback == true`), so the resolver moves straight
/// to the web fallback without making the network call. On the
/// first successful response after the window clears, the entry is
/// dropped immediately so subsequent observations reflect live state.
public struct ClaudeOAuthStrategy: ClaudeSourceStrategy, Sendable {
    public let sourceLabel = "oauth"
    public let sourceType: SourceType = .oauth

    /// Backoff state. Defaults to the process singleton; tests inject
    /// a fresh actor with a controllable clock.
    private let backoff: ClaudeOAuthBackoffState
    /// What `/api/oauth/profile` says about the plan, read at most every 6 h
    /// per token, off the usage path. Defaults to the process singleton;
    /// tests inject their own.
    private let planLabels: ClaudePlanLabelCache

    public init(backoff: ClaudeOAuthBackoffState? = nil, planLabels: ClaudePlanLabelCache? = nil) {
        self.backoff = backoff ?? ClaudeOAuthBackoffState.shared
        self.planLabels = planLabels ?? ClaudePlanLabelCache.shared
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        !ClaudeCredentials.resolveTokenDetails(
            config: config
        ).token.isEmpty
    }

    public func fetch(config: ProviderConfig) async throws -> ClaudeSnapshot {
        let resolved = ClaudeCredentials.resolveTokenDetails(config: config)
        guard !resolved.token.isEmpty else {
            throw ClaudeStrategyError.noToken
        }
        let token = resolved.token
        let tier = resolved.tier

        // Pre-emptive backoff check. If we 429'd this token recently,
        // skip the network round-trip entirely and let the resolver
        // fall through to the web strategy. Avoids hammering Anthropic
        // with calls we already know will fail and risk extending the
        // cooldown window.
        let fingerprint = ClaudeOAuthBackoffState.fingerprint(forToken: token)
        if let remaining = await backoff.remainingBackoff(forFingerprint: fingerprint) {
            throw ClaudeStrategyError.rateLimitBackoff(remaining: remaining)
        }

        let usage: OAuthUsageResponse
        do {
            usage = try await fetchUsage(token: token)
        } catch ClaudeStrategyError.httpError(let status, _) where status == 401 || status == 403 {
            // Token may have rotated — clear the keychain cache so the next
            // attempt re-reads from Claude Code's real keychain item.
            // Persist the tier we DID read from keychain before throwing so
            // the account-info cache keeps feeding the diagnostic copy
            // ("Signed in as X — Connect Claude Code"). Gemini 3.1 Pro review.
            //
            // Note: 401/403 do NOT trigger backoff. Auth failures aren't
            // rate-limit failures — they call for a token refresh, not a
            // cooldown. Recording them in the 429 backoff path would
            // incorrectly suppress retries after the user re-authenticates.
            if let tier, !tier.isEmpty {
                try? ClaudeHelperContract.writeAccountInfo(
                    ClaudeAccountInfo(accountEmail: nil, rateLimitTier: tier, weeklyReset: nil)
                )
            }
            if resolved.source == .sharedKeychain {
                ClaudeCredentials.clearCachedKeychainCredentials()
                // v1.30.x: arm the cross-app keychain-read cooldown so a token
                // that keeps 401ing cannot re-trigger the macOS keychain dialog
                // every refresh. Account-scoped config tokens never mutate
                // another account's shared compatibility cache.
                ClaudeCredentials.installKeychainReadCooldown(cause: .rejectedToken)
            }
            throw ClaudeStrategyError.httpError(status: status, provider: "Claude")
        } catch ClaudeStrategyError.httpError(let status, _) where status == 429 {
            // Genuine rate-limit response. Record the failure so the
            // next refresh cycle skips OAuth pre-emptively. Re-throw
            // so the resolver still logs "[oauth] failed: HTTP 429"
            // for this cycle (the next cycle will log the distinct
            // "rate-limit backoff active" line instead).
            await backoff.recordFailure(forFingerprint: fingerprint)
            throw ClaudeStrategyError.httpError(status: status, provider: "Claude")
        }

        // Success path — clear any backoff entry for this fingerprint
        // so a transient 429 that has just cleared doesn't keep
        // suppressing OAuth until the natural 15-min expiry.
        await backoff.reset(forFingerprint: fingerprint)

        // What Claude calls the plan today. The token's tier is set at sign-in
        // and an Ultra account's still reads Max 20x. Answered from memory at
        // once; a stale or missing read is fetched in the background for the
        // next refresh, so the profile never delays or fails the usage result.
        let profile = await planLabels.profile(forFingerprint: fingerprint) {
            await Self.fetchProfile(token: token)
        }

        return Self.snapshot(
            from: usage,
            rateLimitTier: profile?.rateLimitTier
                ?? tier
                ?? ClaudeCredentials.readCurrentCredentialsFile()?.rateLimitTier
                ?? ClaudeCredentials.readKeychainCredentialsIfAllowed()?.rateLimitTier,
            planDisplayLabel: profile?.planDisplayLabel,
            sourceLabel: sourceLabel
        )
    }

    /// The parsed usage response as the snapshot `fetch` returns. Its own
    /// function so `ClaudeLaneKeysTests` checks the lanes through the same
    /// mapping; the tier is passed in because `fetch` reads it from the
    /// credentials file and the keychain, which tests must not touch.
    static func snapshot(
        from usage: OAuthUsageResponse,
        rateLimitTier: String?,
        planDisplayLabel: String? = nil,
        sourceLabel: String
    ) -> ClaudeSnapshot {
        // `seven_day` is the all-models week; `limits[weekly_all]` says the
        // same where a body leaves `seven_day` out.
        let weekly = usage.sevenDay.map { ($0.utilization, $0.resetsAt) }
            ?? usage.weeklyAll.map { ($0.used, $0.resetsAt) }
        return ClaudeSnapshot(
            sessionUsed: usage.fiveHour?.utilization,
            weeklyUsed: weekly?.0,
            opusUsed: usage.sevenDayOpus?.utilization,
            sonnetUsed: usage.sevenDaySonnet?.utilization,
            dailyRoutinesUsed: usage.routines?.utilization,
            sessionReset: usage.fiveHour?.resetsAt,
            weeklyReset: weekly?.1,
            dailyRoutinesReset: usage.routines?.resetsAt,
            extraUsage: usage.extraUsage.flatMap { e in
                e.isEnabled ? ClaudeExtraUsage(
                    isEnabled: true,
                    monthlyLimit: e.monthlyLimit,
                    usedCredits: e.usedCredits,
                    currency: e.currency
                ) : nil
            },
            rateLimitTier: rateLimitTier,
            sourceLabel: sourceLabel,
            scopedWeekly: usage.scopedWeekly,
            planDisplayLabel: planDisplayLabel
        )
    }

    // MARK: - API

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// The usage GET. Its own function so `CredentialedRequestsLocalCheckTests`
    /// can send the same request through a caching session as its control.
    static func usageRequest(token: String) -> URLRequest {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("CLIPulseBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        return request
    }

    /// Internal for `CredentialedRequestsLocalCheckTests`.
    func fetchUsage(token: String) async throws -> OAuthUsageResponse {
        let (data, response) = try await CredentialedURLSession.shared.data(for: Self.usageRequest(token: token))
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeStrategyError.parseFailed("non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            throw ClaudeStrategyError.httpError(status: http.statusCode, provider: "Claude")
        }
        return try Self.parseUsage(data)
    }

    static let profileURL = URL(string: "https://api.anthropic.com/api/oauth/profile")!

    /// The profile GET: the same bearer token as the usage call. Its own
    /// function so tests can check the request without a network.
    static func profileRequest(token: String) -> URLRequest {
        var request = URLRequest(url: profileURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("CLIPulseBar", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        return request
    }

    /// `/api/oauth/profile` → the plan fields. Any failure is `.failed`; the
    /// cache then keeps what it had and asks again in 30 minutes.
    static func fetchProfile(token: String) async -> ClaudePlanLabelCache.Outcome {
        do {
            let (data, response) = try await CredentialedURLSession.shared.data(for: profileRequest(token: token))
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let profile = parseProfile(data) else {
                return .failed
            }
            return .profile(profile)
        } catch {
            return .failed
        }
    }

    /// Reads two fields of `organization`: `plan_display_label` ("Ultra
    /// plan"; failing that `plan_display_name`) and `rate_limit_tier`. The
    /// body also names the person and the organization; none of that is
    /// kept, logged or returned. Nil when the body has no `organization`.
    static func parseProfile(_ data: Data) -> ClaudePlanLabelCache.Profile? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = json["organization"] as? [String: Any] else { return nil }
        var label: String?
        for key in ["plan_display_label", "plan_display_name"] {
            if let raw = organization[key] as? String, ClaudePlanType.normalizedLabel(raw) != nil {
                label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        let tier = (organization["rate_limit_tier"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudePlanLabelCache.Profile(
            planDisplayLabel: label,
            rateLimitTier: (tier?.isEmpty == false && tier!.count <= 64) ? tier : nil)
    }

    // MARK: - Response types (internal for testing)

    struct UsageWindow: Sendable {
        let utilization: Int
        let resetsAt: String?
    }

    struct ExtraUsage: Sendable {
        let isEnabled: Bool
        let monthlyLimit: Double?
        let usedCredits: Double?
        let utilization: Int?
        let currency: String?
    }

    struct OAuthUsageResponse: Sendable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        /// Daily Routines, from the first of `ClaudeRoutinesWindow.keys`
        /// that holds an object with a numeric utilization; nil otherwise,
        /// so a null window is no row rather than "100% left".
        /// `iguana_necktie` (cloud credits in dollars since 10-01) and
        /// `seven_day_omelette` (the retired Design window) are not read.
        let routines: ClaudeRoutinesWindow.Window?
        let extraUsage: ExtraUsage?
        /// `limits[]`: the weeks scoped to one model, and the all-models
        /// week for a body without `seven_day` (`ClaudeUsageLimits`).
        var scopedWeekly: [ClaudeUsageLimits.Scoped] = []
        var weeklyAll: (used: Int, resetsAt: String?)? = nil
    }

    /// Coerce a JSON value that may be `Int` or `Double` into `Int`.
    ///
    /// Anthropic's OAuth /usage API returns `utilization` as a JSON number that
    /// Foundation decodes as `Double` (e.g. `9.0`). A bare `as? Int` cast on
    /// `NSNumber(Double)` returns `nil`, which previously collapsed every
    /// window's utilization to the `?? 0` fallback — the bug behind
    /// "Quota data unavailable" on macOS. Coercing via `NSNumber` first,
    /// then rounding, handles both `Int` and `Double` shapes.
    static func intFromJSON(_ v: Any?) -> Int? {
        if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
        return nil
    }

    static func parseUsage(_ data: Data) throws -> OAuthUsageResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeStrategyError.parseFailed("invalid JSON")
        }
        func parseWindow(_ key: String) -> UsageWindow? {
            guard let w = json[key] as? [String: Any] else { return nil }
            return UsageWindow(
                utilization: intFromJSON(w["utilization"]) ?? 0,
                resetsAt: w["resets_at"] as? String
            )
        }
        var extra: ExtraUsage? = nil
        if let e = json["extra_usage"] as? [String: Any] {
            // v1.24 Phase 1 Item #7 (CodexBar 11f92065): Anthropic's
            // `/api/oauth/usage` returns `monthly_limit` and `used_credits`
            // in MINOR units (cents) — the same convention as the Web API
            // (`/api/organizations/{orgId}/overage_spend_limit`, where
            // ClaudeWebStrategy.fetchOverageSpendLimit already divides by 100).
            // Convert here so downstream display (which expects dollars)
            // doesn't show 100× values. Upstream lesson: the SpendLimit-vs-OAuth
            // distinction is irrelevant — both endpoints emit cents.
            extra = ExtraUsage(
                isEnabled: e["is_enabled"] as? Bool ?? false,
                monthlyLimit: (e["monthly_limit"] as? NSNumber).map { $0.doubleValue / 100.0 },
                usedCredits: (e["used_credits"] as? NSNumber).map { $0.doubleValue / 100.0 },
                utilization: intFromJSON(e["utilization"]),
                currency: e["currency"] as? String
            )
        }
        return OAuthUsageResponse(
            fiveHour: parseWindow("five_hour"),
            sevenDay: parseWindow("seven_day"),
            sevenDayOpus: parseWindow("seven_day_opus"),
            sevenDaySonnet: parseWindow("seven_day_sonnet"),
            sevenDayOAuthApps: parseWindow("seven_day_oauth_apps"),
            routines: ClaudeRoutinesWindow.parse(json),
            extraUsage: extra,
            scopedWeekly: ClaudeUsageLimits.scopedWeekly(json),
            weeklyAll: ClaudeUsageLimits.weeklyAll(json)
        )
    }
}
#endif
