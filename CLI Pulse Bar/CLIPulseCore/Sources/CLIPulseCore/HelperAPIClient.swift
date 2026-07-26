import Foundation
import os

private let helperLogger = Logger(subsystem: "com.clipulse", category: "HelperAPI")

#if os(macOS)

/// Lightweight Supabase RPC client for the helper daemon.
/// Uses the anon key (not user tokens) — helper authenticates via device secret.
public actor HelperAPIClient {

    private let supabaseURL: String
    private let anonKey: String

    public init(supabaseURL: String, anonKey: String) {
        self.supabaseURL = supabaseURL
        self.anonKey = anonKey
    }

    /// Convenience init reading Supabase config from CLIPulseCore constants.
    public init() {
        self.supabaseURL = SupabaseConstants.url
        self.anonKey = SupabaseConstants.anonKey
    }

    // MARK: - Version reporting (observability only)

    /// The `helper_version` an APP-paired device registers with.
    ///
    /// ⚠️ Intentionally below the remote-command capability floor (1.15.0). The
    /// app's pairing flow registers devices that may have NO command-capable
    /// helper at all (the MAS build ships none — the Swift LaunchAgent helper is
    /// stripped from App Store archives), so registering anything ≥ 1.15.0 here
    /// would make `Device.helperVersionAtLeast(1,15,0)` advertise remote
    /// Codex/Gemini starts that can never execute — they hang pending forever.
    /// A separately-installed helper (`.pkg` Python / bundled Swift) reports its
    /// own real version through its own registration path and is unaffected.
    ///
    /// Use `currentAppVersionString` + `reportAppVersion` for "what version is
    /// this device running" — that is what the observability field is for.
    public static let appPairedHelperVersion = "1.0.0"

    /// This app's version, e.g. `"1.43.0 (96)"`.
    ///
    /// Reported to `devices.app_version` via `reportAppVersion` — an
    /// OBSERVABILITY-ONLY field (migrate_v0.70). It exists because
    /// `devices.helper_version` cannot serve that purpose: 62 of ~68 production
    /// Macs report `"1.0.0"` there (the `registerHelper` default below, which no
    /// caller overrides), and that column ALSO doubles as the remote-command
    /// capability gate (`Device.helperVersionAtLeast(1,15,0)`), so it cannot be
    /// made truthful without falsely advertising remote-command support on MAS
    /// builds — which ship no command-capable helper. Hence a separate field.
    public static var currentAppVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"
        return "\(short) (\(build))"   // well inside the RPC's 32-char clamp
    }

    /// Identity of an app-version report: which device, running which version.
    /// A caller remembers the last key it successfully reported and re-reports
    /// whenever it changes — see `shouldReportAppVersion`.
    public static func appVersionReportKey(deviceId: String, appVersion: String) -> String {
        "\(deviceId)|\(appVersion)"
    }

    /// Whether the app version still needs reporting for this device.
    ///
    /// Deliberately NOT a "did I report yet" flag. The reporting daemon is
    /// long-lived and re-reads its pairing config every cycle, so a user who
    /// re-pairs (or pairs a second device) swaps `deviceId` underneath the
    /// process — with a plain flag that brand-new device row would never
    /// receive a version at all. Keying on (device, version) makes a re-pair
    /// and a version change both self-heal on the next cycle.
    public static func shouldReportAppVersion(
        lastReportedKey: String?,
        deviceId: String,
        appVersion: String = HelperAPIClient.currentAppVersionString
    ) -> Bool {
        lastReportedKey != appVersionReportKey(deviceId: deviceId, appVersion: appVersion)
    }

    /// Report this app's version for fleet observability (migrate_v0.70).
    ///
    /// Deliberately a separate RPC from `heartbeat`: that one is the critical
    /// metrics-ingest path for every device, and this is a diagnostic nicety.
    /// Callers should treat it as best-effort — never let it break a sync.
    public func reportAppVersion(
        config: HelperConfig,
        appVersion: String = HelperAPIClient.currentAppVersionString
    ) async throws {
        let _: [String: Any] = try await rpc("helper_report_app_version", params: [
            "p_device_id": config.deviceId,
            "p_helper_secret": config.helperSecret,
            "p_app_version": appVersion,
        ])
    }

    /// Classify what a SUCCESSFUL collector run actually produced, for the
    /// `collector_status` diagnostic (migrate_v0.71).
    ///
    /// Returns `"ok"` when the collector produced usable usage data, `"empty"`
    /// when it completed without throwing but produced nothing — which is what
    /// the silent-zero class looks like (an inactive sandbox bookmark, an
    /// expired OAuth keychain entry, a drifted API response whose fields all
    /// decode to nil). Distinguishing those two is the entire point of the
    /// field, so this predicate is the load-bearing part of the feature.
    ///
    /// `status_text` is deliberately NOT consulted. It is a non-optional display
    /// string that every collector always fills with literal text — including,
    /// fatally, on its no-data paths ("Claude quota unavailable — Connect in
    /// Settings", "Poe balance unavailable"). Testing it made the predicate a
    /// tautology, so `empty` became dead code and the exact devices this feature
    /// exists to find reported `ok` (independent adversarial review, P1).
    ///
    /// Lives here rather than in the daemon so it is unit-testable: the daemon
    /// is in the app target, out of reach of this package's test suite — which
    /// is precisely how the tautology slipped through.
    public static func classifyCollectorOutcome(
        tiersCount: Int,
        quota: Int?,
        remaining: Int?,
        todayUsage: Int,
        weekUsage: Int
    ) -> String {
        let producedData = tiersCount > 0
            || quota != nil
            || remaining != nil
            || todayUsage > 0
            || weekUsage > 0
        return producedData ? "ok" : "empty"
    }

    /// Report the last collector run's per-provider outcome (migrate_v0.71).
    ///
    /// Answers the question the backend previously could not: when a device is
    /// alive but delivers no usage data, is that because the provider isn't
    /// installed, because the user disabled it, or because the collector RAN and
    /// FAILED (expired auth, parse break, or an inactive sandbox bookmark —
    /// the silent-zero class fixed in 1.30.1)?
    ///
    /// Reported by the sync daemon, since only it runs the collectors. Shares
    /// the v0.70 RPC — each field is coalesced independently server-side, so
    /// omitting `p_app_version` here leaves the app-reported version untouched.
    /// Best-effort, exactly like `reportAppVersion`.
    public func reportCollectorStatus(
        config: HelperConfig,
        status: [String: String]
    ) async throws {
        let _: [String: Any] = try await rpc("helper_report_app_version", params: [
            "p_device_id": config.deviceId,
            "p_helper_secret": config.helperSecret,
            "p_collector_status": status,
        ])
    }

    // MARK: - RPCs (matching backend/supabase/helper_rpc.sql)

    /// Register a helper device via pairing code.
    /// Returns: { device_id, user_id, helper_secret }
    ///
    /// ⚠️ `helperVersion` writes `devices.helper_version`, which is NOT just
    /// observability — the client gates remote Codex/Gemini session starts on
    /// it (`Device.helperVersionAtLeast(1,15,0)`). The `"1.0.0"` default below
    /// looks like a bug and is partly one (see `currentAppVersionString`), but
    /// it is what makes App Store devices — which ship no command-capable
    /// helper — correctly FAIL that gate. Do NOT "fix" it to the real version
    /// without splitting capability out of this column first, or MAS users get
    /// remote-start UI whose commands hang pending forever.
    public func registerHelper(
        pairingCode: String,
        deviceName: String,
        deviceType: String = "macOS",
        system: String = "",
        helperVersion: String = HelperAPIClient.appPairedHelperVersion
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

        let (data, response) = try await URLSession.shared.data(for: request)
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
    public static let url = "https://gkjwsxotmwrgqsvfijzs.supabase.co"
    public static let anonKey: String = {
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String, !key.isEmpty {
            return key
        }
        if let key = ProcessInfo.processInfo.environment["CLI_PULSE_SUPABASE_ANON_KEY"], !key.isEmpty {
            return key
        }
        #if DEBUG
        fatalError("SUPABASE_ANON_KEY missing from Info.plist and environment")
        #else
        helperLogger.error("SUPABASE_ANON_KEY missing — API calls will fail")
        return ""
        #endif
    }()

    /// v1.10 P3-6 launch-time self-check: release builds silently fall through
    /// to `anonKey = ""` when the key is missing (see above), which makes every
    /// API call fail with `HelperAPIError.notConfigured` but leaves the user
    /// staring at a blank, never-loading dashboard. Top-level views read this
    /// flag and render a persistent "configuration error" banner so the
    /// problem is at least visible.
    public static var isConfigured: Bool { !anonKey.isEmpty }
}

// MARK: - Errors

public enum HelperAPIError: LocalizedError {
    case notConfigured
    case invalidURL(String)
    case httpError(status: Int, function: String, body: String)
    case parseFailed(String)
    case pairingRejected(code: String, message: String)

    /// A coarse, PII-free discriminator for diagnostics.
    ///
    /// `String(describing: type(of: error))` collapses every case here to
    /// "HelperAPIError", which makes an expired pairing code indistinguishable
    /// from a network rejection in the field (codex review). This keeps the
    /// case — plus the HTTP status or the server's own rejection CODE, both of
    /// which are enumerated values — while deliberately dropping every
    /// free-text payload (`body`, `message`, URLs) that could carry user data.
    public var diagnosticCode: String {
        switch self {
        case .notConfigured: return "not_configured"
        case .invalidURL: return "invalid_url"
        case .httpError(let status, _, _): return "http_\(status)"
        case .parseFailed: return "parse_failed"
        case .pairingRejected(let code, _): return "rejected_\(code)"
        }
    }

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
