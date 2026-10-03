// v1.56 (P0-17): the API half of the Codex history rebuild's cloud side —
// reading this Mac's own Codex rows (`get_daily_usage_by_device`) and
// upserting the rebuilt ones in batches that report whether they landed.

#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class CodexHistoryCloudAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        RebuildStubProtocol.reset()
    }

    override func tearDown() {
        RebuildStubProtocol.reset()
        super.tearDown()
    }

    private func signedInAPI() async throws -> (APIClient, APIAuthorizationLease) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RebuildStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://codex-rebuild.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config))
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a", refreshToken: "refresh-a", userID: "user-a", transitionGeneration: 1)
        let lease = await api.authorizationLease()
        return (api, try XCTUnwrap(lease))
    }

    private static func row(_ day: String, model: String = "gpt-5") -> CostUsageScanResult.DailyEntry {
        .init(date: day, provider: "Codex", model: model,
              inputTokens: 9_000, cachedTokens: 8_000, outputTokens: 100, costUSD: 1.7)
    }

    private static func body(_ request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - This Mac's rows

    func test_only_this_devices_codex_rows_on_real_days_are_this_macs() {
        let items: [[String: Any]] = [
            ["metric_date": "2026-06-01", "device_id": "AAAA-1", "provider": "Codex", "model": "gpt-5"],
            ["metric_date": "2026-06-01", "device_id": "aaaa-1", "provider": "Codex", "model": "o3"],
            ["metric_date": "2026-06-01", "device_id": "aaaa-1", "provider": "Claude", "model": "claude-sonnet-4-5"],
            ["metric_date": "2026-06-01", "device_id": "bbbb-2", "provider": "Codex", "model": "gpt-5"],
            ["metric_date": "2569-06-01", "device_id": "aaaa-1", "provider": "Codex", "model": "gpt-5"],
            ["metric_date": "2026-06-02", "provider": "Codex", "model": "gpt-5"],
        ]
        let rows = APIClient.codexRows(from: items, deviceId: "aaaa-1")
        XCTAssertEqual(rows, [
            CodexHistoryCloud.Row(date: "2026-06-01", model: "gpt-5"),
            CodexHistoryCloud.Row(date: "2026-06-01", model: "o3"),
        ])
    }

    func test_reading_this_macs_rows_asks_the_by_device_rpc_and_keeps_the_unpaired_stand_ins() async throws {
        RebuildStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/get_daily_usage_by_device")
            return (200, Data("""
            [{"metric_date":"2026-06-01","device_id":"00000000-0000-0000-0000-000000000000","provider":"Codex","model":"gpt-5"},
             {"metric_date":"2026-06-01","device_id":"5b1c7d8e-0000-4000-8000-000000000001","provider":"Codex","model":"gpt-5"},
             {"metric_date":"2026-06-02","device_id":"00000000-0000-0000-0000-000000000000","provider":"Claude","model":"claude-sonnet-4-5"}]
            """.utf8))
        }
        let (api, lease) = try await signedInAPI()

        let rows = await api.codexDailyUsageRows(days: 367, deviceId: nil, authorizationLease: lease)

        XCTAssertEqual(rows, [CodexHistoryCloud.Row(date: "2026-06-01", model: "gpt-5")])
        let request = try XCTUnwrap(RebuildStubProtocol.recordedRequests().first)
        XCTAssertEqual(try Self.body(request)["days"] as? Int, 367)
    }

    func test_a_failed_read_is_nil_not_an_empty_list() async throws {
        RebuildStubProtocol.handler = { _ in (500, Data("{}".utf8)) }
        let (api, lease) = try await signedInAPI()
        let rows = await api.codexDailyUsageRows(days: 367, deviceId: nil, authorizationLease: lease)
        XCTAssertNil(rows, "a failed read looked like a Mac with no rows")
    }

    // MARK: - The upload

    func test_the_upload_goes_in_batches_under_the_device_id_and_says_it_landed() async throws {
        RebuildStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/upsert_daily_usage")
            return (200, Data("{}".utf8))
        }
        let (api, lease) = try await signedInAPI()
        let rows = (0..<450).map { Self.row("2026-06-01", model: "model-\($0)") }

        let paired = await api.upsertDailyUsageRows(rows, deviceId: "dev-1", authorizationLease: lease)

        XCTAssertTrue(paired)
        let requests = RebuildStubProtocol.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let bodies = try requests.map(Self.body)
        XCTAssertEqual(bodies.map { ($0["metrics"] as? [[String: Any]])?.count ?? -1 }, [200, 200, 50])
        XCTAssertEqual(bodies.map { $0["p_device_id"] as? String }, ["dev-1", "dev-1", "dev-1"])
        let first = try XCTUnwrap((bodies.first?["metrics"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["provider"] as? String, "Codex")
        XCTAssertEqual(first["input_tokens"] as? Int, 9_000, "sent in the scanner's basis: input includes cached")
        XCTAssertEqual(first["cached_tokens"] as? Int, 8_000)

        RebuildStubProtocol.reset()
        RebuildStubProtocol.handler = { _ in (200, Data("{}".utf8)) }
        let unpaired = await api.upsertDailyUsageRows([Self.row("2026-06-01")], deviceId: nil, authorizationLease: lease)
        XCTAssertTrue(unpaired)
        let body = try Self.body(try XCTUnwrap(RebuildStubProtocol.recordedRequests().first))
        XCTAssertNil(body["p_device_id"], "the unpaired stand-in is sent as no device id")
    }

    func test_a_failed_batch_stops_the_upload_and_says_so() async throws {
        let calls = Counter()
        RebuildStubProtocol.handler = { _ in
            calls.increment() == 2 ? (500, Data("{}".utf8)) : (200, Data("{}".utf8))
        }
        let (api, lease) = try await signedInAPI()
        let rows = (0..<450).map { Self.row("2026-06-01", model: "model-\($0)") }

        let landed = await api.upsertDailyUsageRows(rows, deviceId: nil, authorizationLease: lease)

        XCTAssertFalse(landed)
        XCTAssertEqual(RebuildStubProtocol.recordedRequests().count, 2, "kept sending after a batch failed")
    }

    // MARK: - Bound to the lease

    func test_the_cloud_side_stops_once_the_account_changes() async throws {
        RebuildStubProtocol.handler = { _ in (200, Data("[]".utf8)) }
        let (api, lease) = try await signedInAPI()
        let built = await api.codexHistoryCloud(authorizationLease: lease)
        let cloud = try XCTUnwrap(built)
        XCTAssertEqual(cloud.account, "user-a")

        // Another sign-in starts: the refresh's lease is no longer current.
        _ = await api.beginExternalAuthorizationTransition(generation: 2)

        let noCloud = await api.codexHistoryCloud(authorizationLease: lease)
        XCTAssertNil(noCloud)
        let rows = await cloud.thisMacsCodexRows(367)
        XCTAssertNil(rows)
        let landed = await cloud.upload([Self.row("2026-06-01")])
        XCTAssertFalse(landed)
        XCTAssertEqual(RebuildStubProtocol.recordedRequests().count, 0, "a stale lease reached the server")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Answers every request with the handler's status and body, and keeps each
/// request with its body read out of the stream.
private final class RebuildStubProtocol: URLProtocol {
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
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
