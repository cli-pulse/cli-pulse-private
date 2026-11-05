#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// The response shapes are upstream CodexBar's fixtures
/// (`MiniMaxTokenPlanChangeTests.swift`), which follow what MiniMax sends.
final class MiniMaxParsingTests: XCTestCase {
    /// 2026-06-01 02:52:20 UTC, inside every window below.
    private let now = Date(timeIntervalSince1970: 1_780_282_340)

    private func parse(_ json: String) throws -> MiniMaxCollector.Parsed {
        try MiniMaxCollector.parseRemainsResponse(Data(json.utf8), now: now)
    }

    private func windows(_ parsed: MiniMaxCollector.Parsed)
        -> (plan: String?, interval: MiniMaxCollector.Window?, weekly: MiniMaxCollector.Window?) {
        guard case let .windows(plan, interval, weekly) = parsed else {
            XCTFail("expected windows, got \(parsed)")
            return (nil, nil, nil)
        }
        return (plan, interval, weekly)
    }

    /// The token plan as MiniMax sends it to a Plus account: a `general` lane
    /// with a 5-hour and a weekly window, and a video lane the plan does not
    /// include (status 3, zero counts, 100 % left).
    private let tokenPlan = """
    {
      "base_resp": { "status_code": 0, "status_msg": "success" },
      "model_remains": [
        {
          "model_name": "video",
          "start_time": 1780243200000, "end_time": 1780329600000,
          "current_interval_total_count": 0, "current_interval_usage_count": 0,
          "current_interval_status": 3, "current_interval_remaining_percent": 100,
          "current_weekly_status": 3, "current_weekly_remaining_percent": 100
        },
        {
          "model_name": "general",
          "start_time": 1780279200000, "end_time": 1780297200000, "remains_time": 14859830,
          "current_interval_total_count": 0, "current_interval_usage_count": 0,
          "current_interval_status": 1, "current_interval_remaining_percent": 96,
          "current_weekly_total_count": 0, "current_weekly_usage_count": 0,
          "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000,
          "current_weekly_status": 1, "current_weekly_remaining_percent": 99
        }
      ]
    }
    """

    func test_tokenPlan_readsTheGeneralLaneAndSkipsTheVideoPlaceholder() throws {
        let w = windows(try parse(tokenPlan))
        XCTAssertNil(w.plan)
        XCTAssertEqual(w.interval, MiniMaxCollector.Window(
            name: "5-hour", remainingPercent: 96,
            resetsAt: Date(timeIntervalSince1970: 1_780_297_200), windowMinutes: 300))
        XCTAssertEqual(w.weekly, MiniMaxCollector.Window(
            name: "Weekly", remainingPercent: 99,
            resetsAt: Date(timeIntervalSince1970: 1_780_848_000), windowMinutes: 10080))
    }

    func test_tokenPlan_buildsTwoPercentTiersWithTheFiveHourOneAsHeadline() throws {
        let result = MiniMaxCollector.buildResult(try parse(tokenPlan))
        XCTAssertEqual(result.dataKind, .quota)
        XCTAssertEqual(result.usage.tiers.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(result.usage.tiers.map(\.remaining), [96, 99])
        XCTAssertEqual(result.usage.tiers.map(\.quota), [100, 100])
        XCTAssertEqual(result.usage.tiers.map(\.windowMinutes), [300, 10080])
        XCTAssertEqual(result.usage.quota, 100)
        XCTAssertEqual(result.usage.remaining, 96)
        XCTAssertEqual(result.usage.plan_type, "Coding Plan")
        XCTAssertEqual(result.usage.status_text, CollectorStatusText.join([
            CollectorStatusText.windowPercentLeft(.fiveHour, 96),
            CollectorStatusText.windowPercentLeft(.weekly, 99),
        ]))
    }

    func test_dataWrappedStringNumbers_parseTheSameAndNameThePlan() throws {
        let w = windows(try parse("""
        {
          "base_resp": { "status_code": "0" },
          "data": {
            "current_subscribe_title": "Token Plan · TokenPlanPlus-年度会员",
            "model_remains": [{
              "model_name": "general",
              "current_interval_total_count": 0, "current_interval_usage_count": 0,
              "current_interval_remaining_percent": "96",
              "start_time": "1780279200000", "end_time": 1780297200000,
              "current_weekly_remaining_percent": "99",
              "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000
            }]
          }
        }
        """))
        XCTAssertEqual(w.plan, "Token Plan · TokenPlanPlus-年度会员")
        XCTAssertEqual(w.interval?.remainingPercent, 96)
        XCTAssertEqual(w.interval?.name, "5-hour")
        XCTAssertEqual(w.weekly?.remainingPercent, 99)
    }

    /// The coding plan before the token plan: counts per text model, where
    /// `current_interval_usage_count` is what is LEFT, not what was used.
    func test_countBasedCodingPlan_usageCountIsTheRemainder() throws {
        let w = windows(try parse("""
        {"model_remains": [{
          "model_name": "MiniMax-M2",
          "start_time": 1780279200, "end_time": 1780297200,
          "current_interval_total_count": 1500, "current_interval_usage_count": 1200
        }]}
        """))
        XCTAssertEqual(w.interval?.remainingPercent, 80)
        XCTAssertEqual(w.interval?.name, "5-hour", "epoch seconds work like milliseconds")
        XCTAssertNil(w.weekly)
    }

    func test_aMediaLaneFirst_isNeverRead() throws {
        let w = windows(try parse("""
        {"model_remains": [
          {"model_name": "video", "current_interval_total_count": 100, "current_interval_usage_count": 30,
           "start_time": 1780243200000, "end_time": 1780329600000},
          {"model_name": "speech-hd", "current_interval_total_count": 100, "current_interval_usage_count": 10},
          {"model_name": "M2.5", "current_interval_total_count": 200, "current_interval_usage_count": 150,
           "start_time": 1780243200000, "end_time": 1780329600000}
        ]}
        """))
        XCTAssertEqual(w.interval?.remainingPercent, 75)
        XCTAssertEqual(w.interval?.name, "Daily")
        XCTAssertEqual(w.interval?.windowMinutes, 1440)
    }

    /// A `general` placeholder must not hide a text model that has a quota.
    func test_aGeneralPlaceholder_fallsThroughToAUsableTextLane() throws {
        let w = windows(try parse("""
        {"model_remains": [
          {"model_name": "general", "current_interval_status": 3,
           "current_interval_total_count": 0, "current_interval_usage_count": 0,
           "current_interval_remaining_percent": 100},
          {"model_name": "MiniMax-M2", "current_interval_total_count": 100, "current_interval_usage_count": 40}
        ]}
        """))
        XCTAssertEqual(w.interval?.remainingPercent, 40)
        XCTAssertEqual(w.interval?.name, "Coding Plan", "no start and end: the length is unknown")
        XCTAssertNil(w.interval?.windowMinutes)
    }

    func test_anUnlimitedWeeklyWindow_isDropped() throws {
        let w = windows(try parse("""
        {"model_remains": [{
          "model_name": "general", "start_time": 1780279200000, "end_time": 1780297200000,
          "current_interval_remaining_percent": 99,
          "current_weekly_total_count": 0, "current_weekly_usage_count": 0,
          "current_weekly_status": 3, "current_weekly_remaining_percent": 100
        }]}
        """))
        XCTAssertEqual(w.interval?.remainingPercent, 99)
        XCTAssertNil(w.weekly)
    }

    func test_weeklyOnly_isTheHeadline() throws {
        let parsed = try parse("""
        {"model_remains": [{
          "model_name": "general",
          "current_weekly_remaining_percent": 35,
          "weekly_start_time": 1780243200000, "weekly_end_time": 1780848000000
        }]}
        """)
        XCTAssertNil(windows(parsed).interval)
        let result = MiniMaxCollector.buildResult(parsed)
        XCTAssertEqual(result.usage.tiers.map(\.name), ["Weekly"])
        XCTAssertEqual(result.usage.remaining, 35)
        XCTAssertEqual(result.usage.reset_time, sharedISO8601Formatter.string(from: Date(timeIntervalSince1970: 1_780_848_000)))
    }

    func test_percentages_areClampedAndRounded() {
        typealias C = MiniMaxCollector
        XCTAssertEqual(C.remainingPercent(percent: 120, total: nil, remaining: nil, status: nil), 100)
        XCTAssertEqual(C.remainingPercent(percent: -5, total: nil, remaining: nil, status: nil), 0)
        XCTAssertEqual(C.remainingPercent(percent: "42.5", total: nil, remaining: nil, status: nil), 43)
        XCTAssertEqual(C.remainingPercent(percent: nil, total: 3, remaining: 2, status: nil), 67)
        XCTAssertEqual(C.remainingPercent(percent: nil, total: 100, remaining: 250, status: nil), 100)
        XCTAssertNil(C.remainingPercent(percent: nil, total: 0, remaining: 0, status: nil), "zero total")
        XCTAssertNil(C.remainingPercent(percent: nil, total: 100, remaining: nil, status: nil), "no count")
        XCTAssertNil(C.remainingPercent(percent: "n/a", total: nil, remaining: nil, status: nil))
        XCTAssertNil(C.remainingPercent(percent: 100, total: 0, remaining: 0, status: 3), "not in this plan")
        XCTAssertEqual(C.remainingPercent(percent: 100, total: 0, remaining: 0, status: 1), 100)
    }

    func test_resets_preferAnEndAheadElseTheTimeLeft() {
        typealias C = MiniMaxCollector
        let ahead = now.addingTimeInterval(600)
        XCTAssertEqual(C.resetsAt(end: ahead, remains: 5_000_000, now: now), ahead)
        let past = now.addingTimeInterval(-600)
        XCTAssertEqual(C.resetsAt(end: past, remains: 5_000_000, now: now), now.addingTimeInterval(5_000),
                       "a stale end falls back to the milliseconds left")
        XCTAssertEqual(C.resetsAt(end: nil, remains: 900, now: now), now.addingTimeInterval(900), "seconds")
        XCTAssertNil(C.resetsAt(end: past, remains: 0, now: now))
        XCTAssertNil(C.date(12345), "not a time")
        XCTAssertEqual(C.date(1_780_297_200), C.date(1_780_297_200_000))
    }

    func test_baseResp1004_isARejectedCredential() {
        XCTAssertThrowsError(try parse(#"{"base_resp": {"status_code": 1004, "status_msg": "cookie is missing, log in again"}}"#)) {
            XCTAssertTrue($0 is MiniMaxCollector.ParseRejection)
        }
        XCTAssertThrowsError(try parse(#"{"base_resp": {"status_code": 2049, "status_msg": "invalid api key"}}"#)) {
            XCTAssertTrue($0 is MiniMaxCollector.ParseRejection)
        }
    }

    func test_anotherStatus_failsWithTheCodeOnly() {
        XCTAssertThrowsError(try parse(#"{"base_resp": {"status_code": 1002, "status_msg": "rate limit for user 12345"}}"#)) {
            guard case CollectorError.parseFailed(let detail) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(detail, "MiniMax: status 1002")
        }
    }

    func test_noUsableLane_isAParseFailure() {
        XCTAssertThrowsError(try parse(#"{"model_remains": [{"model_name": "video", "current_interval_total_count": 10, "current_interval_usage_count": 5}]}"#))
        XCTAssertThrowsError(try parse(#"{"model_remains": []}"#))
        XCTAssertThrowsError(try parse(#"{"base_resp": {"status_code": 0}}"#))
        XCTAssertThrowsError(try MiniMaxCollector.parseRemainsResponse(Data("bad".utf8)))
    }

    /// The flat shape the collector used to expect still parses.
    func test_theOldFlatShape_stillParses() throws {
        let parsed = try parse(#"{"model_remains":800,"total":1000,"end_time":"2026-05-01T00:00:00Z"}"#)
        XCTAssertEqual(parsed, .legacy(.init(modelRemains: 800, total: 1000, endTime: "2026-05-01T00:00:00Z")))
        let zero = try parse(#"{"model_remains":0,"total":500}"#)
        XCTAssertEqual(zero, .legacy(.init(modelRemains: 0, total: 500, endTime: nil)))
    }
}

// MARK: - Fetching

final class MiniMaxFetchTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MiniMaxStubProtocol.reset()
        MiniMaxCollector.resetRememberedRegion()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MiniMaxStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        MiniMaxStubProtocol.reset()
        MiniMaxCollector.resetRememberedRegion()
        super.tearDown()
    }

    private func collector(_ env: [String: String] = [:]) -> MiniMaxCollector {
        MiniMaxCollector(session: session, environment: { env })
    }

    private static let ok = Data(#"{"model_remains":[{"model_name":"general","current_interval_remaining_percent":70}]}"#.utf8)

    private var asked: [String] {
        MiniMaxStubProtocol.recordedRequests().compactMap { r in r.url.map { "\($0.host ?? "")\($0.path)" } }
    }

    func test_aGlobalKey_isAnsweredByTheFirstPath() async throws {
        MiniMaxStubProtocol.handler = { _ in .answer(200, Self.ok) }
        let result = try await collector().collect(config: ProviderConfig(kind: .minimax, apiKey: "k"))
        XCTAssertEqual(result.usage.remaining, 70)
        XCTAssertEqual(asked, ["api.minimax.io/v1/token_plan/remains"])
        let request = try XCTUnwrap(MiniMaxStubProtocol.recordedRequests().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func test_aChinaKey_isAskedInChinaAfterGlobalRejectsIt_andChinaIsRememberedFirst() async throws {
        MiniMaxStubProtocol.handler = { r in r.url?.host == "api.minimaxi.com" ? .answer(200, Self.ok) : .answer(401, Data()) }
        let first = try await collector().fetchWithAPIKey("k")
        XCTAssertEqual(MiniMaxCollector.buildResult(first).usage.remaining, 70)
        XCTAssertEqual(asked, [
            "api.minimax.io/v1/token_plan/remains",
            "api.minimax.io/v1/api/openplatform/coding_plan/remains",
            "api.minimaxi.com/v1/token_plan/remains",
        ])

        MiniMaxStubProtocol.clearRequests()
        _ = try await collector().fetchWithAPIKey("k")
        XCTAssertEqual(asked, ["api.minimaxi.com/v1/token_plan/remains"], "the region that answered goes first")
    }

    /// Upstream's case: the token plan refuses the key, the old path does not
    /// exist on that host, and the key works in China.
    func test_rejectedThenMissing_stillCountsAsRejected() async throws {
        MiniMaxStubProtocol.handler = { r in
            if r.url?.host == "api.minimaxi.com" { return .answer(200, Self.ok) }
            return r.url?.path == "/v1/token_plan/remains" ? .answer(403, Data()) : .answer(404, Data())
        }
        _ = try await collector().fetchWithAPIKey("k")
        XCTAssertEqual(asked.last, "api.minimaxi.com/v1/token_plan/remains")
    }

    func test_aGlobalOutage_doesNotSendTheKeyToChina() async {
        MiniMaxStubProtocol.handler = { _ in .answer(503, Data()) }
        await assertThrows(try await collector().fetchWithAPIKey("k")) {
            guard case CollectorError.httpError(let status, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(status, 503)
        }
        XCTAssertFalse(asked.contains { $0.hasPrefix("api.minimaxi.com") })
    }

    func test_aRejectionBesideAnOutage_isNotCalledRejected() async {
        MiniMaxStubProtocol.handler = { r in
            r.url?.path == "/v1/token_plan/remains" ? .answer(401, Data()) : .failure(URLError(.timedOut))
        }
        await assertThrows(try await collector().fetchWithAPIKey("k")) {
            XCTAssertEqual(($0 as? URLError)?.code, .timedOut)
        }
        XCTAssertFalse(asked.contains { $0.hasPrefix("api.minimaxi.com") })
    }

    func test_aChinaOutageAfterAGlobalRejection_isAnOutageNotARejection() async {
        MiniMaxStubProtocol.handler = { r in r.url?.host == "api.minimaxi.com" ? .answer(502, Data()) : .answer(401, Data()) }
        await assertThrows(try await collector().fetchWithAPIKey("k")) {
            guard case CollectorError.httpError(let status, _) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(status, 502)
        }
    }

    func test_bothRegionsRejecting_isARejectedKey() async {
        MiniMaxStubProtocol.handler = { _ in .answer(200, Data(#"{"base_resp":{"status_code":1004}}"#.utf8)) }
        await assertThrows(try await collector().fetchWithAPIKey("k")) {
            guard case CollectorError.notSignedIn(let problem) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(problem, CredentialProblem("MiniMax", .apiKeyRejected))
        }
        XCTAssertEqual(asked.count, 4)
    }

    func test_aMissingTokenPlanPath_fallsBackToTheCodingPlanPath() async throws {
        MiniMaxStubProtocol.handler = { r in r.url?.path == "/v1/token_plan/remains" ? .answer(404, Data()) : .answer(200, Self.ok) }
        _ = try await collector().fetchWithAPIKey("k")
        XCTAssertEqual(asked, ["api.minimax.io/v1/token_plan/remains",
                               "api.minimax.io/v1/api/openplatform/coding_plan/remains"])
    }

    func test_theHostOverride_isTheOnlyHostAsked() async {
        MiniMaxStubProtocol.handler = { _ in .answer(401, Data()) }
        await assertThrows(try await collector(["MINIMAX_HOST": "mm.example.test"]).fetchWithAPIKey("k")) {
            guard case CollectorError.notSignedIn = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(Set(asked.map { String($0.prefix { $0 != "/" }) }), ["mm.example.test"])
    }

    func test_theURLOverride_isTheOnlyURLAsked_andMustBeHTTPS() async throws {
        MiniMaxStubProtocol.handler = { _ in .answer(200, Self.ok) }
        _ = try await collector(["MINIMAX_REMAINS_URL": "https://mm.example.test/v1/coding_plan/remains"]).fetchWithAPIKey("k")
        XCTAssertEqual(asked, ["mm.example.test/v1/coding_plan/remains"])

        MiniMaxStubProtocol.clearRequests()
        await assertThrows(try await collector(["MINIMAX_REMAINS_URL": "http://mm.example.test/x"]).fetchWithAPIKey("k")) {
            guard case CollectorError.invalidURL = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(asked.isEmpty, "the key is never sent in clear text")
    }

    func test_aRedirectToAnotherHost_isNotFollowed() async {
        MiniMaxStubProtocol.handler = { r in
            r.url?.host == "evil.example.test" ? .answer(200, Self.ok) : .redirect(to: "https://evil.example.test/steal")
        }
        await assertThrows(try await collector().fetchWithAPIKey("k")) { _ in }
        XCTAssertFalse(asked.contains { $0.hasPrefix("evil.example.test") }, "the Bearer header followed a redirect")
    }

    func test_cookieRejection_asksToSignInNotForAKey() async {
        MiniMaxStubProtocol.handler = { _ in .answer(200, Data(#"{"base_resp":{"status_code":1004}}"#.utf8)) }
        let config = ProviderConfig(kind: .minimax, manualCookieHeader: "session=x")
        await assertThrows(try await collector().collect(config: config)) {
            guard case CollectorError.notSignedIn(let problem) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(problem, CredentialProblem("MiniMax", .notSignedInOpenOrPaste("platform.minimax.io")))
        }
    }

    func test_availability() {
        let c = collector()
        XCTAssertTrue(c.isAvailable(config: ProviderConfig(kind: .minimax, apiKey: "key")))
        XCTAssertTrue(c.isAvailable(config: ProviderConfig(kind: .minimax, manualCookieHeader: "session=x")))
        XCTAssertFalse(c.isAvailable(config: ProviderConfig(kind: .minimax)))
        XCTAssertTrue(collector(["MINIMAX_API_KEY": "k"]).isAvailable(config: ProviderConfig(kind: .minimax)))
    }

    func test_theDefaultSession_isTheOneThatKeepsNothing() {
        XCTAssertTrue(MiniMaxCollector().session === CredentialedURLSession.shared)
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T,
                                 file: StaticString = #filePath, line: UInt = #line,
                                 _ check: (Error) -> Void) async {
        do {
            _ = try await body()
            XCTFail("expected an error", file: file, line: line)
        } catch {
            check(error)
        }
    }
}

// MARK: - Rendering

final class MiniMaxRenderingTests: XCTestCase {
    private var saved: String?

    override func setUp() {
        super.setUp()
        saved = LocaleOverrideStore.shared.override
    }

    override func tearDown() {
        LocaleOverrideStore.shared.set(saved)
        super.tearDown()
    }

    /// The tier names are ones the app already translates, so a Chinese reader
    /// does not see English bars.
    func test_theTierNamesRenderInChinese() {
        LocaleOverrideStore.shared.set("zh-Hans")
        for name in ["5-hour", "Daily", "Weekly"] {
            XCTAssertNotEqual(L10n.quotaTier.localized(name), name, name)
        }
        XCTAssertEqual(L10n.quotaTier.localized("Coding Plan"), "Coding Plan", "MiniMax's product name stays")
    }
}

private final class MiniMaxStubProtocol: URLProtocol {
    enum Reply {
        case answer(Int, Data)
        case failure(URLError)
        case redirect(to: String)
    }

    nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = []
    }

    static func clearRequests() {
        lock.lock(); defer { lock.unlock() }
        requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        let url = request.url ?? URL(string: "https://minimax.test")!
        switch handler?(request) ?? .answer(500, Data()) {
        case .answer(let status, let body):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .redirect(let target):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target])!
            var next = request
            next.url = URL(string: target)
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // A refused redirect ends the task with the 3xx itself.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif
