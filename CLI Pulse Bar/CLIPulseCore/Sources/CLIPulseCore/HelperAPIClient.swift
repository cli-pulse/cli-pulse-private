import Foundation
import os

private let helperLogger = Logger(subsystem: "com.clipulse", category: "HelperAPI")

#if os(macOS)

/// Lightweight Supabase RPC client for the helper daemon.
/// Uses the anon key (not user tokens) — helper authenticates via device secret.
public actor HelperAPIClient {

    private let supabaseURL: String
    private let anonKey: String
    private let session: URLSession

    public init(
        supabaseURL: String,
        anonKey: String,
        session: URLSession = .shared
    ) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
        self.session = session
    }

    /// Convenience init reading Supabase config from CLIPulseCore constants.
    public init() {
        self.supabaseURL = SupabaseConstants.url
        self.anonKey = SupabaseConstants.anonKey
        self.session = .shared
    }

    // MARK: - RPCs (matching backend/supabase/helper_rpc.sql)

    /// Register a helper device via pairing code.
    /// Returns: { device_id, user_id, helper_secret }
    public func registerHelper(
        pairingCode: String,
        deviceName: String,
        deviceType: String = "macOS",
        system: String = "",
        helperVersion: String = "1.0.0"
    ) async throws -> HelperConfig {
        let result: [String: Any] = try await rpc("register_helper", params: [
            "p_pairing_code": pairingCode,
            "p_device_name": deviceName,
            "p_device_type": deviceType,
            "p_system": system,
            "p_helper_version": helperVersion,
        ])
        if let errorCode = result["error"] as? String {
            let message = (result["message"] as? String) ?? errorCode
            throw HelperAPIError.pairingRejected(code: errorCode, message: message)
        }
        guard let deviceId = result["device_id"] as? String,
              let userId = result["user_id"] as? String,
              let secret = result["helper_secret"] as? String else {
            throw HelperAPIError.parseFailed("register_helper response missing fields")
        }
        return HelperConfig(
            deviceId: deviceId, userId: userId,
            deviceName: deviceName, helperVersion: helperVersion,
            helperSecret: secret
        )
    }

    /// Send a heartbeat with device metrics.
    ///
    /// `providerPlanStatus` (v0.60): the per-provider managed-session plan map
    /// ({"codex":"off_plan",…}) so phones can warn before starting an off-plan
    /// (billed) managed session. Pass `nil` when it couldn't be determined — the
    /// param is then OMITTED and the server's `coalesce` preserves the last-known
    /// value (never clobbers to `{}` on a transient miss). An empty map is sent
    /// as-is (authoritative "nothing off-plan").
    public func heartbeat(
        config: HelperConfig,
        cpuUsage: Int,
        memoryUsage: Int,
        activeSessionCount: Int,
        providerPlanStatus: [String: String]? = nil
    ) async throws {
        var params: [String: Any] = [
            "p_device_id": config.deviceId,
            "p_helper_secret": config.helperSecret,
            "p_cpu_usage": cpuUsage,
            "p_memory_usage": memoryUsage,
            "p_active_session_count": activeSessionCount,
        ]
        if let providerPlanStatus {
            params["p_provider_plan_status"] = providerPlanStatus
        }
        let _: [String: Any] = try await rpc("helper_heartbeat", params: params)
    }

    /// Sync sessions, alerts, and provider quota data.
    ///
    /// - `sessions`: array of session dicts with id, name, provider, project, etc.
    /// - `alerts`: array of alert dicts with id, type, severity, title, etc.
    /// - `providerRemaining`: flat { provider: remaining } for legacy compat
    /// - `providerTiers`: full { provider: { quota, remaining, plan_type, reset_time, tiers: [...] } }
    public func sync(
        config: HelperConfig,
        sessions: [[String: Any]],
        alerts: [[String: Any]],
        providerRemaining: [String: Int],
        providerTiers: [String: Any]
    ) async throws -> (sessionsSynced: Int, alertsSynced: Int) {
        let result: [String: Any] = try await rpc("helper_sync", params: [
            "p_device_id": config.deviceId,
            "p_helper_secret": config.helperSecret,
            "p_sessions": sessions,
            "p_alerts": alerts,
            "p_provider_remaining": providerRemaining,
            "p_provider_tiers": providerTiers,
        ])
        return (
            sessionsSynced: result["sessions_synced"] as? Int ?? 0,
            alertsSynced: result["alerts_synced"] as? Int ?? 0
        )
    }

    /// Builds the legacy provider quota projection without sending collector
    /// diagnostics or external account identifiers to the backend.
    public nonisolated static func legacyProviderTiers(
        from providers: [String: HelperIPC.CollectorUsagePayload]
    ) -> [String: Any] {
        providers.mapValues { payload in
            var tierData: [String: Any] = [
                "quota": payload.quota ?? 100,
                "remaining": payload.remaining ?? 100,
            ]
            if let planType =
                ProviderAccountCloudPrivacy.reviewedPlanType(
                    payload.planType
                )
            {
                tierData["plan_type"] = planType
            }
            if let resetTime = payload.resetTime {
                tierData["reset_time"] = resetTime
            }
            tierData["tiers"] = (payload.tiers ?? []).map {
                Self.tierDictionary($0)
            }
            return tierData
        }
    }

    /// Builds the legacy provider projection from account-scoped observations
    /// owned by the paired CLIPulse user. Filtering before collapsing by
    /// provider prevents another local user's same-provider account from
    /// becoming the compatibility row.
    public nonisolated static func legacyProviderTiers(
        from accounts: [HelperIPC.CollectorAccountPayload],
        configs: [ProviderConfig],
        ownedBy userID: String
    ) -> [String: Any] {
        let syncableAccountIDs =
            ProviderAccountSyncOwnership.accountIDs(
                in: configs,
                ownedBy: userID
            )
        var providers:
            [String: HelperIPC.CollectorUsagePayload] = [:]
        for account in accounts
        where syncableAccountIDs.contains(account.accountID) {
            if providers[account.provider] == nil {
                providers[account.provider] = account.usage
            }
        }
        return legacyProviderTiers(from: providers)
    }

    /// Sync account-scoped quota observations through the device-authenticated
    /// v2 helper RPC. Provider credentials never enter the IPC payload and are
    /// structurally absent from the rows encoded here.
    public func syncProviderAccountQuotas(
        config: HelperConfig,
        accounts: [HelperIPC.CollectorAccountPayload],
        observedAt: Date
    ) async throws -> Int {
        let observedAtString =
            sharedISO8601Formatter.string(from: observedAt)
        let rows: [[String: Any]] = accounts.compactMap { account in
            guard
                account.dataKind == .quota
                    || account.dataKind == .credits
            else {
                return nil
            }

            let override =
                ProviderAccountCloudPrivacy.reviewedPlanType(
                    account.planOverride
                )
            let detected =
                ProviderAccountCloudPrivacy.reviewedPlanType(
                    account.usage.planType
                )
            let planType: String?
            let planSource: String
            let planConfidence: String
            let planObservedAt: String?
            if let override, !override.isEmpty {
                planType = override
                planSource = "userConfirmed"
                planConfidence = "high"
                planObservedAt = observedAtString
            } else if let detected, !detected.isEmpty {
                planType = detected
                planSource = "unknown"
                planConfidence = "low"
                planObservedAt = observedAtString
            } else {
                planType = nil
                planSource = "unknown"
                planConfidence = "unavailable"
                planObservedAt = nil
            }

            var row: [String: Any] = [
                "account_id":
                    account.accountID.uuidString.lowercased(),
                "provider": account.provider,
                "plan_source": planSource,
                "plan_confidence": planConfidence,
                "tiers":
                    ProviderAccountCloudPrivacy.reviewedTiers(
                        account.usage.tiers ?? []
                    ).map { Self.tierDictionary($0) },
                "observed_at": observedAtString,
            ]
            if let label =
                ProviderAccountCloudPrivacy
                    .reviewedAccountLabel(
                        account.accountLabel
                    )
            {
                row["account_label"] = label
            }
            if let planType {
                row["plan_type"] = planType
            }
            if let planObservedAt {
                row["plan_observed_at"] = planObservedAt
            }
            if let remaining =
                ProviderAccountCloudPrivacy
                    .reviewedNonNegativeValue(
                        account.usage.remaining
                    )
            {
                row["remaining"] = remaining
            }
            if let quota =
                ProviderAccountCloudPrivacy
                    .reviewedNonNegativeValue(
                        account.usage.quota
                    )
            {
                row["quota"] = quota
            }
            if let resetTime =
                ProviderAccountCloudPrivacy
                    .reviewedTimestamp(
                        account.usage.resetTime
                    )
            {
                row["reset_time"] = resetTime
            }
            return row
        }
        guard !rows.isEmpty else { return 0 }

        let result: [String: Any] = try await rpc(
            "helper_sync_provider_account_quotas",
            params: [
                "p_device_id": config.deviceId,
                "p_helper_secret": config.helperSecret,
                "p_rows": rows,
            ]
        )
        return result["accounts_synced"] as? Int ?? 0
    }

    private nonisolated static func tierDictionary(
        _ tier: TierDTO
    ) -> [String: Any] {
        var value: [String: Any] = [
            "name": tier.name,
            "quota": tier.quota,
            "remaining": tier.remaining,
        ]
        if let resetTime = tier.reset_time {
            value["reset_time"] = resetTime
        }
        if let windowMinutes = tier.windowMinutes {
            value["windowMinutes"] = windowMinutes
        }
        if let role = tier.role {
            value["role"] = role.rawValue
        }
        return value
    }

    // MARK: - Generic RPC

    /// True when the client has a non-empty Supabase URL and anon key.
    /// Callers can check this before attempting RPCs to surface a clear
    /// "not configured" state rather than chasing mysterious HTTP failures.
    public var isConfigured: Bool {
        !supabaseURL.isEmpty && !anonKey.isEmpty
    }

    private func rpc<T>(_ function: String, params: [String: Any]) async throws -> T {
        guard isConfigured else {
            throw HelperAPIError.notConfigured
        }
        guard let url = URL(string: "\(supabaseURL)/rest/v1/rpc/\(function)") else {
            throw HelperAPIError.invalidURL(function)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue("CLIPulseHelper/1.0", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        request.httpBody = try JSONSerialization.data(withJSONObject: params)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw HelperAPIError.parseFailed("non-HTTP response from \(function)")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw HelperAPIError.httpError(status: http.statusCode, function: function, body: body)
        }

        guard let result = try JSONSerialization.jsonObject(with: data) as? T else {
            throw HelperAPIError.parseFailed("cannot decode \(function) response as \(T.self)")
        }
        return result
    }
}
#endif

// MARK: - Supabase Constants (centralized)

public enum SupabaseConstants {
    private static let configuration: RuntimeCloudConfiguration = {
        let runtimeEnvironment = CLIPulseRuntimeEnvironment.current
        var infoDictionary = Bundle.main.infoDictionary ?? [:]
        var environment = ProcessInfo.processInfo.environment
        if (infoDictionary["SUPABASE_ANON_KEY"] as? String)?.isEmpty == true {
            infoDictionary.removeValue(forKey: "SUPABASE_ANON_KEY")
        }
        if environment["CLI_PULSE_SUPABASE_ANON_KEY"]?.isEmpty == true {
            environment.removeValue(forKey: "CLI_PULSE_SUPABASE_ANON_KEY")
        }
        let resolved = RuntimeCloudConfiguration.resolve(
            runtimeEnvironment: runtimeEnvironment,
            explicitURL: nil,
            explicitAnonKey: nil,
            infoDictionary: infoDictionary,
            environment: environment
        )
        guard runtimeEnvironment.allowsProductionCloudEndpoints,
              resolved.anonKey.isEmpty
        else {
            return resolved
        }
        #if DEBUG
        fatalError("SUPABASE_ANON_KEY missing from Info.plist and environment")
        #else
        helperLogger.error("SUPABASE_ANON_KEY missing — API calls will fail")
        return resolved
        #endif
    }()
    public static var url: String { configuration.url }
    public static var anonKey: String { configuration.anonKey }

    /// v1.10 P3-6 launch-time self-check: release builds silently fall through
    /// to `anonKey = ""` when the key is missing (see above), which makes every
    /// API call fail with `HelperAPIError.notConfigured` but leaves the user
    /// staring at a blank, never-loading dashboard. Top-level views read this
    /// flag and render a persistent "configuration error" banner so the
    /// problem is at least visible.
    public static var isConfigured: Bool {
        !configuration.url.isEmpty && !configuration.anonKey.isEmpty
    }
}

// MARK: - Errors

public enum HelperAPIError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case httpError(status: Int, function: String, body: String)
    case parseFailed(String)
    case pairingRejected(code: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return "HelperAPIClient is not configured — SUPABASE_ANON_KEY is missing or empty"
        case .invalidURL(let fn): return "Invalid URL for \(fn)"
        case .httpError(let s, let fn, let body): return "HTTP \(s) from \(fn): \(body.prefix(200))"
        case .parseFailed(let msg): return "Parse failed: \(msg)"
        case .pairingRejected(_, let message): return message
        }
    }
}
