import Foundation

/// Fetches Codex (OpenAI) usage via the WHAM rate-limit API. Reads
/// the access token from `~/.codex/auth.json` (Codex CLI's standard
/// persistence location), then GETs
/// `https://chatgpt.com/backend-api/wham/usage`.
///
/// Phase 4E Slice 2c — port of `_fetch_codex_usage` +
/// `_parse_codex_usage_response`. Token-loading is the only path
/// (no Keychain involvement; no OAuth refresh).
public actor CodexQuotaFetcher {

    public typealias HTTPHook = @Sendable (URLRequest) async -> (Data, HTTPURLResponse)?
    public typealias FileLoader = @Sendable (URL) async -> Data?

    private let authFilePath: URL
    private let http: HTTPHook
    private let fileLoader: FileLoader
    private let now: @Sendable () -> Date

    public init(
        authFilePath: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        http: @escaping HTTPHook = ClaudeQuotaFetcher.liveHTTP,
        fileLoader: @escaping FileLoader = { url in
            try? Data(contentsOf: url)
        },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authFilePath = authFilePath
        self.http = http
        self.fileLoader = fileLoader
        self.now = now
    }

    public func fetch() async -> ProviderQuotaSnapshot {
        let formatter = SessionDetector.makeISOFormatter()
        let nowISO = formatter.string(from: now())

        // Step 1: Load auth.json
        guard let raw = await fileLoader(authFilePath) else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_file_missing", fetchedAt: nowISO
            )
        }
        guard let outer = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_parse_error", fetchedAt: nowISO
            )
        }
        let token = Self.extractAccessToken(from: outer)
        guard let token = token, !token.isEmpty else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "auth_token_missing", fetchedAt: nowISO
            )
        }

        // Step 2: HTTP
        guard let url = URL(string: "https://chatgpt.com/backend-api/wham/usage") else {
            return ClaudeQuotaFetcher.unavailable(reason: "url_construction", fetchedAt: nowISO)
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("CLI-Pulse-Helper/Swift", forHTTPHeaderField: "User-Agent")

        guard let (body, response) = await http(req) else {
            return ClaudeQuotaFetcher.unavailable(reason: "network_error", fetchedAt: nowISO)
        }
        guard (200...299).contains(response.statusCode) else {
            return ClaudeQuotaFetcher.unavailable(
                reason: "http_\(response.statusCode)", fetchedAt: nowISO
            )
        }
        return Self.parseUsageResponse(body, fetchedAt: nowISO)
    }

    /// Extract the access token from the auth.json structure. Two
    /// shapes supported: flat `tokens.access_token` or nested
    /// `tokens.<key>.access_token` (Codex versions vary).
    static func extractAccessToken(from outer: [String: Any]) -> String? {
        guard let tokens = outer["tokens"] as? [String: Any] else { return nil }
        if let flat = tokens["access_token"] as? String, !flat.isEmpty {
            return flat
        }
        for (_, value) in tokens {
            if let nested = value as? [String: Any],
               let access = nested["access_token"] as? String,
               !access.isEmpty {
                return access
            }
        }
        return nil
    }

    /// Mirrors Python `_parse_codex_usage_response`. Format:
    /// `{"plan_type": "plus", "rate_limit": {"primary_window": {"used_percent": N, ...}}}`.
    ///
    /// Each window is placed by its length (`limit_window_seconds`), not by
    /// the slot it came in — an account with only a weekly limit gets it in
    /// `primary_window` — and carries `windowMinutes` and `role`, the same
    /// table as the app's `CodexCollector` (`CodexRateWindowNormalizer`).
    /// It is named by its length too (`tierName`), so this helper and the app
    /// store the same name for the same window, apart from this helper's own
    /// word for the 5-hour one ("Session").
    static func parseUsageResponse(_ body: Data, fetchedAt: String) -> ProviderQuotaSnapshot {
        guard let dict = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return ClaudeQuotaFetcher.unavailable(reason: "parse_error", fetchedAt: fetchedAt)
        }
        let planRaw = (dict["plan_type"] as? String) ?? "Plus"
        let plan = planRaw.prefix(1).uppercased() + planRaw.dropFirst().lowercased()

        var tiers: [ProviderQuotaTier] = []
        let formatter = SessionDetector.makeISOFormatter()

        if let rl = dict["rate_limit"] as? [String: Any] {
            var slots: [Window?] = []
            for key in ["primary_window", "secondary_window"] {
                guard let win = rl[key] as? [String: Any] else {
                    slots.append(nil)
                    continue
                }
                let usedAny = win["used_percent"]
                let used: Double
                if let d = usedAny as? Double { used = d }
                else if let i = usedAny as? Int { used = Double(i) }
                else {
                    slots.append(nil)
                    continue
                }

                var resetISO: String? = nil
                if let resetTs = win["reset_at"] as? Double {
                    resetISO = formatter.string(from: Date(timeIntervalSince1970: resetTs))
                } else if let resetTs = win["reset_at"] as? Int {
                    resetISO = formatter.string(from: Date(timeIntervalSince1970: TimeInterval(resetTs)))
                }
                slots.append(Window(
                    used: used,
                    reset: resetISO,
                    minutes: Self.windowMinutes(win["limit_window_seconds"])
                ))
            }
            let lanes = Self.lanes(primary: slots[0], secondary: slots[1])
            for (window, isSession) in [(lanes.session, true), (lanes.weekly, false)] {
                guard let window else { continue }
                tiers.append(ProviderQuotaTier(
                    name: Self.tierName(
                        minutes: window.minutes,
                        laneName: isSession ? "Session" : "Weekly",
                        besides: tiers.first?.name
                    ),
                    quota: 100,
                    remaining: max(0, 100 - Int(window.used)),
                    resetTime: window.reset,
                    windowMinutes: window.minutes,
                    role: isSession ? "primary" : "secondary"
                ))
            }
        }
        guard let primary = tiers.first else {
            return ClaudeQuotaFetcher.unavailable(reason: "no_tiers", fetchedAt: fetchedAt)
        }
        return ProviderQuotaSnapshot(
            quota: primary.quota,
            remaining: primary.remaining,
            planType: plan,
            resetTime: primary.resetTime,
            tiers: tiers,
            provenance: .openAIWham,
            fetchedAt: fetchedAt
        )
    }

    // MARK: - Window names (same table as the app's CodexQuotaWindows.tierName)

    /// The stored name of a Codex window: the name of its length, else
    /// `laneName`. A window of UNKNOWN length keeps the name its lane has
    /// always had, the only information there is. `besides` is the name the
    /// other window already got: two bars under one name cannot be told
    /// apart (and the app keys its bars by name), so the second of two
    /// same-named windows is the generic "Window" — or, when the first is
    /// already "Window", its lane's name. Mirrors Python `_codex_tier_name`.
    static func tierName(minutes: Int?, laneName: String, besides: String? = nil) -> String {
        let name: String
        switch minutes {
        case 300?: name = "Session"
        case 1440?: name = "Daily"
        case 10080?: name = "Weekly"
        case 43200?: name = "Monthly"
        case .some: name = "Window"
        case nil: name = laneName
        }
        guard name == besides else { return name }
        return name == "Window" ? laneName : "Window"
    }

    // MARK: - Window lanes (same table as the app's CodexRateWindowNormalizer)

    struct Window: Equatable {
        let used: Double
        let reset: String?
        let minutes: Int?
    }

    /// Minutes from `limit_window_seconds`; missing or under a minute is
    /// unknown.
    static func windowMinutes(_ raw: Any?) -> Int? {
        let seconds: Int?
        if let i = raw as? Int { seconds = i }
        else if let d = raw as? Double { seconds = Int(d) }
        else { seconds = nil }
        guard let seconds, seconds / 60 > 0 else { return nil }
        return seconds / 60
    }

    private enum LaneRole { case session, weekly, unknown }

    private static func laneRole(_ window: Window) -> LaneRole {
        switch window.minutes {
        case 300: return .session
        case 10080: return .weekly
        default: return .unknown
        }
    }

    /// The two API slots put in the lanes their lengths say. Line for line
    /// the table of the app's `CodexRateWindowNormalizer` (ported from
    /// CodexBar), so the helper and the app file every window under the same
    /// lane. A lone window is the weekly lane if it is 10080 minutes long and
    /// the session lane otherwise, whichever slot it came in. Of two windows,
    /// a weekly one in the primary slot swaps with the other (unless that is
    /// weekly too); otherwise each keeps its slot.
    static func lanes(
        primary: Window?,
        secondary: Window?
    ) -> (session: Window?, weekly: Window?) {
        switch (primary, secondary) {
        case let (.some(p), .some(s)):
            switch (laneRole(p), laneRole(s)) {
            case (.weekly, .session), (.weekly, .unknown):
                return (s, p)
            default:
                return (p, s)
            }
        case let (.some(p), .none):
            return laneRole(p) == .weekly ? (nil, p) : (p, nil)
        case let (.none, .some(s)):
            return laneRole(s) == .weekly ? (nil, s) : (s, nil)
        case (.none, .none):
            return (nil, nil)
        }
    }
}
