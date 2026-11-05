// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/MiniMax/MiniMaxUsageFetcher.swift,
// MiniMaxAPIRegion.swift and MiniMaxModelRemains.swift
// (https://github.com/steipete/CodexBar). Ported: the `model_remains` response
// model (per-model lanes, `*_usage_count` meaning REMAINING, payload at the top
// level or under `data`, numbers that arrive as strings), the placeholder-lane
// rule (status 3, zero counts, 100 % left), the epoch-seconds-or-milliseconds
// times, the two API paths, and the China mainland host tried when the global
// one rejects the key. The fetch is reimplemented on `CredentialedURLSession`.
//
// 1.62 (P6). Until 1.61 this collector read a guessed flat shape
// (`{"model_remains": 800, "total": 1000}`), so a real account got no tier and
// "Unknown"; that shape still parses in case anything returns it.
//
// Divergences from upstream, on purpose:
//   * Only the text lane (`general`, or a MiniMax-M / M2.x model) is read.
//     Video, speech, image and music lanes are not coding-tool quota.
//   * Percent only: boost capacity, "Unlimited" weekly rows, points balance and
//     the inferred "Plus" plan name are not ported. An unlimited weekly window is
//     dropped rather than drawn.
//   * No region setting: the region that answered is remembered in memory.
//   * The China web console (cookie path on minimaxi.com) is not added.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

#if os(macOS)
import Foundation

/// Fetches the MiniMax coding / token plan quota.
///
/// API key (`config.apiKey` or `MINIMAX_API_KEY`, preferred):
/// `GET https://api.minimax.io/v1/token_plan/remains`, then
/// `/v1/api/openplatform/coding_plan/remains`; when the global host rejects the
/// key, the same two on `api.minimaxi.com` (China mainland keys only work
/// there). Overrides: `MINIMAX_REMAINS_URL` (that https URL only) or
/// `MINIMAX_HOST` (that host only, both paths).
///
/// Cookie (`MINIMAX_COOKIE` or `config.manualCookieHeader`, less reliable:
/// MiniMax often answers 1004 to cookies alone):
/// `GET https://platform.minimax.io/v1/api/openplatform/coding_plan/remains`.
public struct MiniMaxCollector: ProviderCollector, Sendable {
    public let kind = ProviderKind.minimax

    private static let cookieEnvVars = ["MINIMAX_COOKIE", "MINIMAX_COOKIE_HEADER"]
    private static let cookieDomains = ["minimax.io", "platform.minimax.io"]

    /// The session that keeps nothing; tests hand in one with a stub protocol.
    let session: URLSession
    private let environment: @Sendable () -> [String: String]

    public init() {
        self.init(session: CredentialedURLSession.shared, environment: { ProcessInfo.processInfo.environment })
    }

    init(session: URLSession, environment: @escaping @Sendable () -> [String: String]) {
        self.session = session
        self.environment = environment
    }

    public func isAvailable(config: ProviderConfig) -> Bool {
        resolveAPIToken(config: config) != nil
            || hasManualOrEnvCookie(config: config)
            || config.cookieSource == .automatic
    }

    public func collect(config: ProviderConfig) async throws -> CollectorResult {
        if let token = resolveAPIToken(config: config) {
            return Self.buildResult(try await fetchWithAPIKey(token))
        }
        let resolution = await CookieResolver.resolve(
            config: config,
            envVarNames: Self.cookieEnvVars,
            domains: Self.cookieDomains
        )
        if let cookie = resolution.headerValue {
            return Self.buildResult(try await fetchWithCookie(cookie))
        }
        throw CollectorError.missingCredentials(CredentialProblem("MiniMax", .noAPIKeyOrCookie))
    }

    private func resolveAPIToken(config: ProviderConfig) -> String? {
        if let k = config.apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty { return k }
        if let k = environment()["MINIMAX_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !k.isEmpty { return k }
        return nil
    }

    private func hasManualOrEnvCookie(config: ProviderConfig) -> Bool {
        if let c = config.manualCookieHeader, !c.isEmpty { return true }
        let env = environment()
        for name in Self.cookieEnvVars where !(env[name] ?? "").isEmpty {
            return true
        }
        return false
    }

    // MARK: - Regions and endpoints

    enum Region: String, CaseIterable, Sendable {
        case global
        case chinaMainland

        var apiHost: String {
            switch self {
            case .global: return "api.minimax.io"
            case .chinaMainland: return "api.minimaxi.com"
            }
        }

        var other: Region { self == .global ? .chinaMainland : .global }
    }

    /// Newest first: the token plan, then the coding plan it replaced.
    static let apiPaths = ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"]

    /// The region whose host last accepted the key. In memory only: after a
    /// relaunch a China key costs at most two extra requests to learn it again.
    private static let rememberedRegion = RegionMemory()

    /// Forgets the remembered region (tests).
    static func resetRememberedRegion() { rememberedRegion.set(.global) }

    // MARK: - Fetch (API key)

    /// How one request ended.
    enum Attempt: Sendable {
        case ok(Parsed)
        /// 401/403, `base_resp` 1004, "invalid api key".
        case rejected
        /// 404/405: this host does not serve this path.
        case missing(status: Int)
        /// Anything else: another status, a network error, a redirect off the
        /// host, an answer we cannot read. We do not know what the key is worth.
        case unavailable(Error)
    }

    /// What a region's attempts add up to (see `regionVerdict`).
    enum Verdict: Sendable {
        case ok(Parsed)
        case rejected
        case unavailable(Error)
    }

    /// A region rejected the key only if some path rejected it and every other
    /// path rejected it too or does not exist there. One outage or unreadable
    /// answer makes the region `unavailable`: a key must never be called
    /// rejected because a server was down.
    static func regionVerdict(_ attempts: [Attempt]) -> Verdict {
        var sawRejection = false
        var lastMissing: Int?
        for attempt in attempts {
            switch attempt {
            case .ok(let parsed): return .ok(parsed)
            case .rejected: sawRejection = true
            case .missing(let status): lastMissing = status
            case .unavailable: break
            }
        }
        if let outage = attempts.lazy.compactMap({ attempt -> Error? in
            if case .unavailable(let error) = attempt { return error }
            return nil
        }).first {
            return .unavailable(outage)
        }
        if sawRejection { return .rejected }
        return .unavailable(CollectorError.httpError(status: lastMissing ?? 0, provider: "MiniMax"))
    }

    func fetchWithAPIKey(_ token: String) async throws -> Parsed {
        let env = environment()
        if let override = env["MINIMAX_REMAINS_URL"], !override.isEmpty {
            guard let url = Self.httpsURL(override) else { throw CollectorError.invalidURL("MINIMAX_REMAINS_URL") }
            return try Self.settle(Self.regionVerdict([try await attempt(url: url, token: token)]))
        }
        if let host = env["MINIMAX_HOST"], !host.isEmpty {
            return try Self.settle(try await verdict(host: host, token: token))
        }

        let first = Self.rememberedRegion.get()
        let firstVerdict = try await verdict(host: first.apiHost, token: token)
        switch firstVerdict {
        case .ok(let parsed):
            return parsed
        case .unavailable(let error):
            throw error
        case .rejected:
            // A key from the other region is rejected here: ask there, once.
            let second = first.other
            let secondVerdict = try await verdict(host: second.apiHost, token: token)
            if case .ok = secondVerdict { Self.rememberedRegion.set(second) }
            return try Self.settle(secondVerdict)
        }
    }

    private static func settle(_ verdict: Verdict) throws -> Parsed {
        switch verdict {
        case .ok(let parsed): return parsed
        case .rejected: throw CollectorError.notSignedIn(CredentialProblem("MiniMax", .apiKeyRejected))
        case .unavailable(let error): throw error
        }
    }

    private func verdict(host: String, token: String) async throws -> Verdict {
        var attempts: [Attempt] = []
        for path in Self.apiPaths {
            guard let url = Self.httpsURL("https://\(host)\(path)") else {
                throw CollectorError.invalidURL("MINIMAX_HOST")
            }
            let result = try await attempt(url: url, token: token)
            if case .ok = result { return Self.regionVerdict([result]) }
            attempts.append(result)
        }
        return Self.regionVerdict(attempts)
    }

    private func attempt(url: URL, token: String) async throws -> Attempt {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CLIPulseBar", forHTTPHeaderField: "MM-API-Source")
        request.timeoutInterval = 15
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
        } catch {
            if Self.isCancellation(error) { throw error }
            return .unavailable(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 401, 403: return .rejected
        case 404, 405: return .missing(status: status)
        case 200...299: break
        default: return .unavailable(CollectorError.httpError(status: status, provider: "MiniMax"))
        }
        do {
            return .ok(try Self.parseRemainsResponse(data))
        } catch ParseRejection.credential {
            return .rejected
        } catch {
            return .unavailable(error)
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// An https URL with a host, else nil: an override cannot send the key in
    /// clear text.
    static func httpsURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    // MARK: - Fetch (cookie)

    private func fetchWithCookie(_ cookie: String) async throws -> Parsed {
        let host = environment()["MINIMAX_HOST"] ?? "platform.minimax.io"
        let urlStr = "https://\(host)/v1/api/openplatform/coding_plan/remains"
        guard let url = Self.httpsURL(urlStr) else { throw CollectorError.invalidURL(urlStr) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "x-requested-with")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request, delegate: SameHostRedirects.shared)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let signIn = CollectorError.notSignedIn(CredentialProblem("MiniMax", .notSignedInOpenOrPaste("platform.minimax.io")))
        if status == 401 || status == 403 { throw signIn }
        guard (200...299).contains(status) else {
            throw CollectorError.httpError(status: status, provider: "MiniMax")
        }
        do {
            return try Self.parseRemainsResponse(data)
        } catch ParseRejection.credential {
            throw signIn
        }
    }

    // MARK: - Parsing

    /// The answer refused the credential (`base_resp` 1004 or a sign-in message).
    enum ParseRejection: Error { case credential }

    /// One quota window, as a percentage left.
    struct Window: Equatable, Sendable {
        let name: String
        let remainingPercent: Int
        let resetsAt: Date?
        let windowMinutes: Int?
    }

    /// The flat shape this collector used to expect. Never observed; kept so
    /// anything that does return it keeps working.
    struct LegacyRemains: Equatable, Sendable {
        let modelRemains: Int
        let total: Int
        let endTime: String?
    }

    enum Parsed: Equatable, Sendable {
        case windows(plan: String?, interval: Window?, weekly: Window?)
        case legacy(LegacyRemains)
    }

    static func parseRemainsResponse(_ data: Data, now: Date = Date()) throws -> Parsed {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.parseFailed("MiniMax: invalid JSON")
        }
        let body = json["data"] as? [String: Any] ?? json

        if let base = (body["base_resp"] ?? json["base_resp"]) as? [String: Any],
           let code = number(base["status_code"]), code != 0 {
            let message = (base["status_msg"] as? String ?? "").lowercased()
            if code == 1004 || ["invalid api key", "log in", "login", "cookie"].contains(where: message.contains) {
                throw ParseRejection.credential
            }
            // The code only: the vendor's message stays out of logs and the UI.
            throw CollectorError.parseFailed("MiniMax: status \(Int(code))")
        }

        if let remains = number(json["model_remains"]) {
            let total = number(json["total"]) ?? 0
            let endTime = json["end_time"] as? String ?? json["remains_time"] as? String
            return .legacy(LegacyRemains(modelRemains: Int(remains), total: Int(total), endTime: endTime))
        }

        guard let lanes = body["model_remains"] as? [[String: Any]] ?? json["model_remains"] as? [[String: Any]] else {
            throw CollectorError.parseFailed("MiniMax: no coding plan quota")
        }
        // `general` first, then any text model in the order MiniMax sent them.
        let textLanes = lanes.filter { isTextLane($0["model_name"] as? String) }
        let ordered = textLanes.filter { ($0["model_name"] as? String)?.lowercased() == "general" }
            + textLanes.filter { ($0["model_name"] as? String)?.lowercased() != "general" }
        for lane in ordered {
            let interval = intervalWindow(lane, now: now)
            let weekly = weeklyWindow(lane, now: now)
            if interval != nil || weekly != nil {
                return .windows(plan: planName(body), interval: interval, weekly: weekly)
            }
        }
        throw CollectorError.parseFailed("MiniMax: no coding plan quota")
    }

    /// `general` (the token plan's text bucket) or a text model by name.
    static func isTextLane(_ name: String?) -> Bool {
        guard let lower = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return lower == "general" || lower.contains("minimax-m") || lower.hasPrefix("m2.")
    }

    private static func intervalWindow(_ lane: [String: Any], now: Date) -> Window? {
        let start = date(lane["start_time"])
        let end = date(lane["end_time"])
        guard let remaining = remainingPercent(
            percent: lane["current_interval_remaining_percent"],
            total: lane["current_interval_total_count"],
            remaining: lane["current_interval_usage_count"],
            status: lane["current_interval_status"]
        ) else { return nil }
        let minutes = windowMinutes(start: start, end: end)
        let name: String
        switch minutes {
        case .some(240...360): name = "5-hour"
        case .some(1380...1500): name = "Daily"
        default: name = "Coding Plan"
        }
        return Window(name: name, remainingPercent: remaining,
                      resetsAt: resetsAt(end: end, remains: lane["remains_time"], now: now),
                      windowMinutes: minutes)
    }

    private static func weeklyWindow(_ lane: [String: Any], now: Date) -> Window? {
        let status = number(lane["current_weekly_status"])
        let percent = number(lane["current_weekly_remaining_percent"])
        // Upstream's "no weekly limit" signature.
        if status == 3, let percent, percent >= 100 { return nil }
        guard let remaining = remainingPercent(
            percent: lane["current_weekly_remaining_percent"],
            total: lane["current_weekly_total_count"],
            remaining: lane["current_weekly_usage_count"],
            status: lane["current_weekly_status"]
        ) else { return nil }
        let end = date(lane["weekly_end_time"])
        return Window(name: "Weekly", remainingPercent: remaining,
                      resetsAt: resetsAt(end: end, remains: lane["weekly_remains_time"], now: now),
                      windowMinutes: 10080)
    }

    /// Percent left, 0…100: the percent MiniMax sends, else remaining / total.
    /// Nil for a window this plan does not have (status 3, zero counts, 100 %
    /// left) or one with nothing to measure.
    static func remainingPercent(percent: Any?, total: Any?, remaining: Any?, status: Any?) -> Int? {
        let percent = number(percent)
        let total = number(total)
        let remaining = number(remaining)
        if number(status) == 3, (total ?? 0) == 0, (remaining ?? 0) == 0, (percent ?? 0) >= 100 {
            return nil
        }
        let value: Double
        if let percent {
            value = percent
        } else if let total, total > 0, let remaining {
            value = 100 * remaining / total
        } else {
            return nil
        }
        return Int(min(100, max(0, value)).rounded())
    }

    private static func planName(_ body: [String: Any]) -> String? {
        let card = (body["current_combo_card"] as? [String: Any])?["title"]
        return [body["current_subscribe_title"], body["plan_name"], body["combo_title"],
                body["current_plan_title"], card]
            .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    /// A finite number from an NSNumber or a numeric string.
    static func number(_ value: Any?) -> Double? {
        let result: Double?
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
            result = n.doubleValue
        case let s as String:
            result = Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            result = nil
        }
        guard let result, result.isFinite else { return nil }
        return result
    }

    /// Epoch milliseconds or seconds; anything smaller is not a time.
    static func date(_ value: Any?) -> Date? {
        guard let raw = number(value) else { return nil }
        if raw > 1_000_000_000_000 { return Date(timeIntervalSince1970: raw / 1000) }
        if raw > 1_000_000_000 { return Date(timeIntervalSince1970: raw) }
        return nil
    }

    private static func windowMinutes(start: Date?, end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        return minutes > 0 ? minutes : nil
    }

    /// The window's end if it is still ahead, else now plus the time MiniMax
    /// says is left (milliseconds above a million, else seconds).
    static func resetsAt(end: Date?, remains: Any?, now: Date) -> Date? {
        if let end, end > now { return end }
        guard let remains = number(remains), remains > 0 else { return nil }
        return now.addingTimeInterval(remains > 1_000_000 ? remains / 1000 : remains)
    }

    // MARK: - Result

    static func buildResult(_ parsed: Parsed) -> CollectorResult {
        switch parsed {
        case .legacy(let m):
            return buildLegacyResult(m)
        case let .windows(plan, interval, weekly):
            let tiers = [interval, weekly].compactMap { $0 }.map { w in
                TierDTO(name: w.name, quota: 100, remaining: w.remainingPercent,
                        reset_time: w.resetsAt.map { sharedISO8601Formatter.string(from: $0) },
                        windowMinutes: w.windowMinutes, role: nil)
            }
            let headline = tiers.first
            let segments = [interval, weekly].compactMap { $0 }.map { w -> String in
                switch w.name {
                case "5-hour": return CollectorStatusText.windowPercentLeft(.fiveHour, w.remainingPercent)
                case "Daily": return CollectorStatusText.windowPercentLeft(.daily, w.remainingPercent)
                case "Weekly": return CollectorStatusText.windowPercentLeft(.weekly, w.remainingPercent)
                default: return CollectorStatusText.percentLeft(w.remainingPercent)
                }
            }
            let usage = ProviderUsage(
                provider: ProviderKind.minimax.rawValue,
                today_usage: 0, week_usage: 0,
                estimated_cost_today: 0, estimated_cost_week: 0,
                cost_status_today: "Unavailable", cost_status_week: "Unavailable",
                quota: 100, remaining: headline?.remaining ?? 0,
                plan_type: plan ?? "Coding Plan", reset_time: headline?.reset_time, tiers: tiers,
                status_text: CollectorStatusText.join(segments),
                trend: [], recent_sessions: [], recent_errors: [],
                metadata: ProviderMetadata(display_name: "MiniMax", category: "cloud",
                                           supports_exact_cost: false, supports_quota: true))
            return CollectorResult(usage: usage, dataKind: .quota)
        }
    }

    private static func buildLegacyResult(_ m: LegacyRemains) -> CollectorResult {
        let used = max(0, m.total - m.modelRemains)
        var tiers: [TierDTO] = []
        if m.total > 0 {
            tiers.append(TierDTO(name: "Coding Plan", quota: m.total,
                                 remaining: m.modelRemains, reset_time: m.endTime))
        }

        let usage = ProviderUsage(
            provider: ProviderKind.minimax.rawValue,
            today_usage: used, week_usage: used,
            estimated_cost_today: 0, estimated_cost_week: 0,
            cost_status_today: "Unavailable", cost_status_week: "Unavailable",
            quota: m.total > 0 ? m.total : nil, remaining: m.modelRemains,
            plan_type: "Coding Plan", reset_time: m.endTime, tiers: tiers,
            status_text: m.total > 0 ? CollectorStatusText.usedOf("\(used)", "\(m.total)") : "Unknown",
            trend: [], recent_sessions: [], recent_errors: [],
            metadata: ProviderMetadata(display_name: "MiniMax", category: "cloud",
                                       supports_exact_cost: false, supports_quota: true))
        return CollectorResult(usage: usage, dataKind: .quota)
    }
}

/// The remembered region, behind a lock (collectors run concurrently).
private final class RegionMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var region: MiniMaxCollector.Region = .global

    func get() -> MiniMaxCollector.Region {
        lock.lock(); defer { lock.unlock() }
        return region
    }

    func set(_ value: MiniMaxCollector.Region) {
        lock.lock(); defer { lock.unlock() }
        region = value
    }
}

/// Follows a redirect only to the same host, so the `Authorization` header or
/// the cookie cannot be carried to another one. A refused redirect ends the
/// request with the 3xx, which reads as `unavailable`.
private final class SameHostRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = SameHostRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        let from = response.url?.host?.lowercased()
        let to = request.url?.host?.lowercased()
        guard let from, from == to, request.url?.scheme?.lowercased() == "https" else { return nil }
        return request
    }
}
#endif
