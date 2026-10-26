// 59-01 / 59-01a (1.59): what `syncDailyUsage` returns, and its one token
// refresh on a 401.
//
// Up to 1.58 the daily-usage POST was the one request of a refresh that did
// not refresh an expired token: `rpc` and `restGet` retry once after a 401,
// `postDailyUsage` logged the status and dropped that refresh's rows. Now it
// refreshes and retries once, under the same lease rules as `rpc`: never as
// another account, never twice, and a refresh token the server rejects is
// `.sessionExpired`, which the refresh turns into the same sign-out a read
// would.
//
// macOS-gated: `syncDailyUsage` is macOS-only.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class DailyUsageUploadOutcomeTests: XCTestCase {

    private static let replacePath = "/rest/v1/rpc/replace_daily_usage"
    private static let upsertPath = "/rest/v1/rpc/upsert_daily_usage"
    private static let tokenPath = "/auth/v1/token"
    private static let rotated = #"{"access_token":"token-a-rotated","refresh_token":"refresh-a-rotated"}"#

    override func setUp() {
        super.setUp()
        UploadOutcomeStubProtocol.reset()
    }

    override func tearDown() {
        UploadOutcomeStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - 59-01a: one refresh, one retry

    func test_a_401_refreshes_the_token_and_sends_once_more_with_it() async throws {
        let replaceCalls = LockedCounter()
        UploadOutcomeStubProtocol.respond { request in
            switch request.url?.path {
            case Self.replacePath:
                return replaceCalls.next() == 1 ? .status(401) : .status(200, #"{"upserted":1}"#)
            case Self.tokenPath:
                return .status(200, Self.rotated)
            default:
                return .status(500)
            }
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .uploaded(rows: 1, status: 200, afterTokenRefresh: true))
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [Self.replacePath, Self.tokenPath, Self.replacePath])
        let posts = UploadOutcomeStubProtocol.requests().filter { $0.url?.path == Self.replacePath }
        XCTAssertEqual(posts.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer token-a", "Bearer token-a-rotated"],
                       "the retry must carry the refreshed token")
        XCTAssertEqual(posts.first?.httpBody, posts.last?.httpBody, "the retry sends the same rows")
        let token = await api.getToken()
        XCTAssertEqual(token, "token-a-rotated")
    }

    func test_a_second_401_is_reported_and_not_retried_again() async throws {
        UploadOutcomeStubProtocol.respond { request in
            request.url?.path == Self.tokenPath ? .status(200, Self.rotated) : .status(401)
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .unauthorized(afterRetry: true))
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [Self.replacePath, Self.tokenPath, Self.replacePath],
                       "one refresh and one retry, never a loop")
    }

    func test_a_rejected_refresh_token_is_session_expired_and_sends_nothing_more() async throws {
        UploadOutcomeStubProtocol.respond { request in
            request.url?.path == Self.tokenPath
                ? .status(400, #"{"error":"invalid_grant"}"#)
                : .status(401)
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .sessionExpired)
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [Self.replacePath, Self.tokenPath])
        // The same state a read leaves behind, which `consumeTokenExpiry`
        // turns into exactly one sign-out for this session.
        let consumed = await api.consumeTokenExpiry(for: lease)
        XCTAssertTrue(consumed, "the refresh must hand the expiry to the lease that saw it")
    }

    func test_a_refresh_that_gets_no_answer_is_a_401_without_a_retry() async throws {
        UploadOutcomeStubProtocol.respond { request in
            request.url?.path == Self.tokenPath ? .fail(URLError(.cannotConnectToHost)) : .status(401)
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .unauthorized(afterRetry: false))
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [Self.replacePath, Self.tokenPath])
    }

    /// An account switch while the token refresh is out must not let the
    /// retry go out at all: not as the old account (its session is gone) and
    /// never with the new account's token.
    func test_an_account_switch_during_the_refresh_stops_the_retry() async throws {
        let refreshStarted = expectation(description: "refresh started")
        UploadOutcomeStubProtocol.respond { request in
            if request.url?.path == Self.tokenPath {
                refreshStarted.fulfill()
                return .status(200, Self.rotated, delay: 0.25)
            }
            return .status(401)
        }
        let (api, lease) = try await signedInAPI()

        let sync = Task { await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now) }
        await fulfillment(of: [refreshStarted], timeout: 3)
        await api.updateToken("token-b")
        await api.updateRefreshToken("refresh-b")
        let outcome = await sync.value

        XCTAssertEqual(outcome, .authorizationChanged)
        let posts = UploadOutcomeStubProtocol.requests().filter { $0.url?.path == Self.replacePath }
        XCTAssertEqual(posts.count, 1, "no retry after the account changed")
        XCTAssertFalse(posts.contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token-b" })
    }

    /// The 404 fallback after a refreshed `replace_daily_usage` attempt: the
    /// outcome still says the token was refreshed on the way.
    func test_a_refresh_before_the_404_fallback_is_reported() async throws {
        let replaceCalls = LockedCounter()
        UploadOutcomeStubProtocol.respond { request in
            switch request.url?.path {
            case Self.replacePath:
                return replaceCalls.next() == 1 ? .status(401) : .status(404, #"{"code":"PGRST202"}"#)
            case Self.tokenPath:
                return .status(200, Self.rotated)
            case Self.upsertPath:
                return .status(200, "{}")
            default:
                return .status(500)
            }
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .uploaded(rows: 1, status: 200, afterTokenRefresh: true))
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(),
                       [Self.replacePath, Self.tokenPath, Self.replacePath, Self.upsertPath])
        XCTAssertEqual(UploadOutcomeStubProtocol.requests().last?.value(forHTTPHeaderField: "Authorization"),
                       "Bearer token-a-rotated")
    }

    // MARK: - 59-01: the other outcomes

    func test_success_reports_the_rows_sent_and_the_status() async throws {
        UploadOutcomeStubProtocol.respond { _ in .status(204) }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(rows: 3), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .uploaded(rows: 3, status: 204, afterTokenRefresh: false))
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [Self.replacePath], "a success refreshes nothing")
    }

    func test_a_server_error_is_rejected_with_its_status() async throws {
        UploadOutcomeStubProtocol.respond { _ in .status(403, #"{"code":"42501"}"#) }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(outcome, .rejected(status: 403))
    }

    func test_the_fallback_reports_its_own_status() async throws {
        UploadOutcomeStubProtocol.respond { request in
            request.url?.path == Self.replacePath ? .status(404) : .status(500)
        }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(outcome, .rejected(status: 500))
    }

    func test_no_answer_is_network_failed() async throws {
        UploadOutcomeStubProtocol.respond { _ in .fail(URLError(.cannotConnectToHost)) }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(outcome, .networkFailed)
    }

    func test_no_network_is_offline_not_a_failure() async throws {
        UploadOutcomeStubProtocol.respond { _ in .fail(URLError(.dataNotAllowed)) }
        let (api, lease) = try await signedInAPI()

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(outcome, .offline)
    }

    func test_a_stale_lease_sends_nothing_and_says_so() async throws {
        UploadOutcomeStubProtocol.respond { _ in .status(200) }
        let (api, lease) = try await signedInAPI()
        await api.updateToken("token-b")

        let outcome = await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(outcome, .authorizationChanged)
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [])
    }

    /// Rows that `dailyUsageRowsToUpload` leaves out entirely (only the
    /// message bucket here) are "nothing to upload", not an empty scan.
    func test_a_scan_with_nothing_to_send_says_so() async throws {
        UploadOutcomeStubProtocol.respond { _ in .status(200) }
        let (api, lease) = try await signedInAPI()

        let onlyMessages = CostUsageScanResult(entries: [
            .init(date: DayKey.string(from: Self.now), provider: "Claude", model: ScanEntry.messageBucketModel,
                  inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: nil, messageCount: 3),
        ])
        let outcome = await api.syncDailyUsage(onlyMessages, authorizationLease: lease, now: Self.now)
        XCTAssertEqual(outcome, .nothingToUpload)

        let empty = await api.syncDailyUsage(CostUsageScanResult(entries: []), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(empty, .scanEmpty)
        XCTAssertEqual(UploadOutcomeStubProtocol.paths(), [])
    }

    // MARK: - Fixtures

    private static let now = ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z")!

    private static func scan(rows: Int = 1) -> CostUsageScanResult {
        CostUsageScanResult(entries: (0..<rows).map { index in
            .init(date: DayKey.string(from: now), provider: "Codex", model: "gpt-5.\(index)",
                  inputTokens: 100, cachedTokens: 0, outputTokens: 5, costUSD: 0.01)
        })
    }

    private func signedInAPI() async throws -> (APIClient, APIAuthorizationLease) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UploadOutcomeStubProtocol.self]
        let api = APIClient(
            token: nil,
            supabaseURL: "https://upload-outcome.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config),
            providerAccountFlags: .init(readV2: false, writeV2: false)
        )
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a",
            refreshToken: "refresh-a",
            userID: "user-a",
            transitionGeneration: 1
        )
        let lease = await api.authorizationLease()
        return (api, try XCTUnwrap(lease))
    }
}

final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// 1 on the first call, 2 on the second, …
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

/// Records every request and answers from `respond`. A delayed answer is
/// delivered from another queue, so one slow request does not hold up the
/// others (a stub that sleeps in `startLoading` serializes all of them).
final class UploadOutcomeStubProtocol: URLProtocol {
    enum Answer {
        case status(Int, String = "{}", delay: TimeInterval = 0)
        case fail(Error)
    }
    typealias Responder = (URLRequest) -> Answer

    nonisolated(unsafe) private static var responder: Responder?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    private static let lock = NSLock()

    static func respond(_ responder: @escaping Responder) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        recorded = []
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func paths() -> [String] { requests().compactMap(\.url?.path) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            copy.httpBodyStream = nil
            copy.httpBody = data
        }
        Self.lock.lock()
        Self.recorded.append(copy)
        let responder = Self.responder
        Self.lock.unlock()

        switch responder?(copy) ?? .status(500) {
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let status, let body, let delay):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            let deliver = { [weak self] in
                guard let self, let client = self.client else { return }
                client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client.urlProtocol(self, didLoad: Data(body.utf8))
                client.urlProtocolDidFinishLoading(self)
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
            } else {
                deliver()
            }
        }
    }

    override func stopLoading() {}
}
#endif
