// v1.57: reading the account's daily rows (`get_daily_usage`) for the Mac's
// provider cards and Cost Summary. A failed read must not look like an
// account with no rows, and the read must reach the user's oldest day.

import XCTest
@testable import CLIPulseCore

final class DailyUsageFetchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        DailyUsageStubProtocol.reset()
    }

    override func tearDown() {
        DailyUsageStubProtocol.reset()
        super.tearDown()
    }

    private func api(signedIn: Bool) async -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DailyUsageStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://daily-usage.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config))
        if signedIn {
            _ = await api.beginExternalAuthorizationTransition(generation: 1)
            _ = await api.installExternalAuthenticatedSession(
                accessToken: "token-a", refreshToken: "refresh-a", userID: "user-a", transitionGeneration: 1)
        }
        return api
    }

    func test_rows_come_back_for_the_days_asked() async throws {
        DailyUsageStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_daily_usage")
            return (200, Data("""
            [{"metric_date":"2026-10-14","provider":"Codex","model":"gpt-5.5",
              "input_tokens":100,"cached_tokens":0,"output_tokens":20,"cost":1.5}]
            """.utf8))
        }
        let api = await api(signedIn: true)
        let rows = await api.fetchDailyUsageRows(days: AppState.dailyUsageFetchDays)
        XCTAssertEqual(rows?.map(\.id), ["2026-10-14-Codex-gpt-5.5"])
        let request = try XCTUnwrap(DailyUsageStubProtocol.recordedRequests().first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["days"] as? Int, 31, "the cards' 30 days and one for the server's UTC date")
    }

    func test_a_failed_read_is_nil_not_an_empty_account() async {
        DailyUsageStubProtocol.handler = { _ in (500, Data("{}".utf8)) }
        let api = await api(signedIn: true)
        let failed = await api.fetchDailyUsageRows(days: 31)
        XCTAssertNil(failed, "a failed read looked like an account with no rows")
        // The older entry point keeps its contract for its callers.
        let legacy = await api.fetchDailyUsage(days: 31)
        XCTAssertTrue(legacy.isEmpty)

        DailyUsageStubProtocol.handler = { _ in (200, Data("not json".utf8)) }
        let unreadable = await api.fetchDailyUsageRows(days: 31)
        XCTAssertNil(unreadable)
    }

    func test_signed_out_there_are_no_rows_and_nothing_is_asked() async {
        DailyUsageStubProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let api = await api(signedIn: false)
        let rows = await api.fetchDailyUsageRows(days: 31)
        XCTAssertEqual(rows?.count, 0)
        XCTAssertTrue(DailyUsageStubProtocol.recordedRequests().isEmpty)
    }
}

private final class DailyUsageStubProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handler = nil
        requests = []
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if recorded.httpBody == nil, let stream = recorded.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBodyStream = nil
            recorded.httpBody = data
        }
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()

        let (status, body) = handler?(recorded) ?? (500, Data())
        let response = HTTPURLResponse(
            url: recorded.url ?? URL(string: "https://daily-usage.test")!,
            statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
