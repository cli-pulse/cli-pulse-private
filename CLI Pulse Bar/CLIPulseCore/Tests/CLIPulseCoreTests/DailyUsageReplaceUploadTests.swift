// v1.56: the daily-usage upload replaces a device's (day, provider) whole.
//
// `upsert_daily_usage` never deletes. When the app renamed a model
// (`claude-haiku-4-5-20251001` -> `claude-haiku-4-5`, the day a price row for
// it landed), the cloud kept both rows and the iPhone counted the day's usage
// of that model twice. The upload now goes to `replace_daily_usage`
// (migrate_v0.84), which also deletes this device's rows of each (day,
// provider) sent whose model is not in the upload (for the nil UUID that
// unpaired Macs share, migrate_v0.85: only a dated spelling of a model sent).
// The SQL half is tested by backend/supabase/tests/run_v084_* and run_v085_*;
// this is the app's half:
//
//   * the upload goes to the new RPC;
//   * while the server answers 404 for it (the migration is applied by the
//     owner, possibly after this version ships), the same body goes to
//     `upsert_daily_usage`, and the new RPC is asked again an hour later;
//   * any other failure is not a reason to send the rows somewhere else;
//   * and what the app sends for a (day, provider) is all of it, because the
//     server now deletes what is missing.
//
// macOS-gated: `syncDailyUsage` is macOS-only.

#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class DailyUsageReplaceUploadTests: XCTestCase {

    private static let replacePath = "/rest/v1/rpc/replace_daily_usage"
    private static let upsertPath = "/rest/v1/rpc/upsert_daily_usage"

    override func setUp() {
        super.setUp()
        DailyUsageReplaceStubProtocol.reset()
    }

    override func tearDown() {
        DailyUsageReplaceStubProtocol.reset()
        super.tearDown()
    }

    // MARK: - Where the rows go

    func test_the_upload_goes_to_replace_daily_usage() async throws {
        DailyUsageReplaceStubProtocol.respond { _ in (200, #"{"upserted":1,"removed":1}"#) }
        let (api, lease) = try await signedInAPI()

        await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])
        let body = try XCTUnwrap(DailyUsageReplaceStubProtocol.requests().first?.httpBody)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let metrics = try XCTUnwrap(root["metrics"] as? [[String: Any]])
        XCTAssertEqual(metrics.map { $0["model"] as? String }, ["claude-haiku-4-5"])
    }

    func test_a_404_sends_the_same_body_to_upsert_daily_usage() async throws {
        DailyUsageReplaceStubProtocol.respond { request in
            request.url?.path == Self.replacePath
                ? (404, #"{"code":"PGRST202","message":"Could not find the function"}"#)
                : (200, #"{"upserted":1}"#)
        }
        let (api, lease) = try await signedInAPI()

        await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)

        XCTAssertEqual(
            DailyUsageReplaceStubProtocol.paths(), [Self.replacePath, Self.upsertPath],
            "a server without migrate_v0.84 must still receive the day's rows")
        let bodies = DailyUsageReplaceStubProtocol.requests().map(\.httpBody)
        guard bodies.count == 2 else { return }
        XCTAssertNotNil(bodies[0])
        XCTAssertEqual(bodies[0], bodies[1], "the fallback must send exactly what the new RPC was sent")
    }

    func test_after_a_404_the_new_rpc_is_asked_again_an_hour_later() async throws {
        let serverHasIt = LockedFlag()
        DailyUsageReplaceStubProtocol.respond { request in
            if request.url?.path == Self.replacePath, !serverHasIt.value { return (404, "{}") }
            return (200, "{}")
        }
        let (api, lease) = try await signedInAPI()

        await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath, Self.upsertPath])

        // Within the hour: straight to the old RPC, no second 404 per refresh.
        DailyUsageReplaceStubProtocol.clearRequests()
        await api.syncDailyUsage(
            Self.scan(), authorizationLease: lease,
            now: Self.now.addingTimeInterval(APIClient.replaceDailyUsageRetryInterval - 60))
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.upsertPath])

        // The owner applies the migration; after the hour the app finds it.
        serverHasIt.value = true
        DailyUsageReplaceStubProtocol.clearRequests()
        await api.syncDailyUsage(
            Self.scan(), authorizationLease: lease,
            now: Self.now.addingTimeInterval(APIClient.replaceDailyUsageRetryInterval))
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])

        // And keeps using it.
        DailyUsageReplaceStubProtocol.clearRequests()
        await api.syncDailyUsage(
            Self.scan(), authorizationLease: lease,
            now: Self.now.addingTimeInterval(APIClient.replaceDailyUsageRetryInterval + 60))
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])
    }

    func test_a_failure_other_than_404_is_not_sent_to_the_old_rpc() async throws {
        DailyUsageReplaceStubProtocol.respond { _ in (500, #"{"message":"boom"}"#) }
        let (api, lease) = try await signedInAPI()

        await api.syncDailyUsage(Self.scan(), authorizationLease: lease, now: Self.now)
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])

        // Nor does it stop asking the new RPC.
        DailyUsageReplaceStubProtocol.clearRequests()
        await api.syncDailyUsage(
            Self.scan(), authorizationLease: lease, now: Self.now.addingTimeInterval(60))
        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])
    }

    // MARK: - Under which device

    /// A paired Mac sends its device id, and so does one whose helper secret
    /// cannot be read right now: the login keychain locks with the screen,
    /// and the refresh keeps running. That Mac used to send its whole window
    /// under the unpaired stand-in as well, and `get_daily_usage` added that
    /// copy to the paired one on the iPhone, for good. Only a Mac with no
    /// pairing record for the signed-in account sends no device id.
    func test_a_mac_paired_with_the_account_sends_its_device_id_even_when_the_secret_cannot_be_read() async throws {
        DailyUsageReplaceStubProtocol.respond { _ in (200, "{}") }
        let (api, lease) = try await signedInAPI()

        func sentDeviceId(_ device: APIClient.DailyUsageDevice) async throws -> String? {
            DailyUsageReplaceStubProtocol.clearRequests()
            var askedFor: [String] = []
            await api.syncDailyUsage(
                Self.scan(), authorizationLease: lease, now: Self.now,
                device: { user in askedFor.append(user); return device })
            XCTAssertEqual(askedFor, ["user-a"], "the device must be decided for the signed-in account, once")
            XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath])
            let body = try XCTUnwrap(DailyUsageReplaceStubProtocol.requests().first?.httpBody)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return root["p_device_id"] as? String
        }

        let paired = try await sentDeviceId(.paired("dev-1"))
        XCTAssertEqual(paired, "dev-1")
        let secretUnreadable = try await sentDeviceId(.undetermined("dev-1"))
        XCTAssertEqual(
            secretUnreadable, "dev-1",
            "a locked keychain sent a paired Mac's rows under the unpaired stand-in")
        let unpaired = try await sentDeviceId(.unpaired)
        XCTAssertNil(unpaired, "a Mac without a pairing for this account is the stand-in")
    }

    /// The 404 fallback sends the same device id: it sends the same body.
    func test_the_fallback_keeps_the_device_id_of_a_mac_whose_secret_cannot_be_read() async throws {
        DailyUsageReplaceStubProtocol.respond { request in
            request.url?.path == Self.replacePath ? (404, "{}") : (200, "{}")
        }
        let (api, lease) = try await signedInAPI()

        await api.syncDailyUsage(
            Self.scan(), authorizationLease: lease, now: Self.now, device: { _ in .undetermined("dev-1") })

        XCTAssertEqual(DailyUsageReplaceStubProtocol.paths(), [Self.replacePath, Self.upsertPath])
        let ids = try DailyUsageReplaceStubProtocol.requests().map { request -> String? in
            let body = try XCTUnwrap(request.httpBody)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return root["p_device_id"] as? String
        }
        XCTAssertEqual(ids, ["dev-1", "dev-1"])
    }

    // MARK: - What is sent for a (day, provider) is all of it

    /// `replace_daily_usage` deletes this device's rows of a (day, provider)
    /// sent whose model is not in the upload. So `dailyUsageRowsToUpload` may
    /// leave out a whole (day, provider), never part of one: a model it left
    /// out of a group it sent would be deleted from the cloud. The message
    /// bucket is the one exception, and it is not a model.
    ///
    /// Checked at every hour across three days, so the day Claude Code's
    /// cleanup is working through moves across the data, including rows with
    /// no input (output only) and no cost.
    func test_the_upload_never_sends_part_of_a_day_and_provider() throws {
        let base = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-01T00:30:00Z"))
        var entries: [CostUsageScanResult.DailyEntry] = []
        for offset in -34...1 {
            let day = DayKey.string(from: base.addingTimeInterval(Double(offset) * 86_400))
            entries += [
                .init(date: day, provider: "Claude", model: "claude-opus-5", inputTokens: 100,
                      cachedTokens: 10, outputTokens: 20, costUSD: 1.5),
                .init(date: day, provider: "Claude", model: "claude-haiku-4-5", inputTokens: 0,
                      cachedTokens: 0, outputTokens: 7, costUSD: nil),
                .init(date: day, provider: "Claude", model: ScanEntry.messageBucketModel,
                      inputTokens: 0, cachedTokens: 0, outputTokens: 0, costUSD: nil, messageCount: 4),
                .init(date: day, provider: "Codex", model: "gpt-5.5", inputTokens: 300,
                      cachedTokens: 200, outputTokens: 5, costUSD: 0.4),
                .init(date: day, provider: "Codex", model: "gpt-5.5-mini", inputTokens: 0,
                      cachedTokens: 0, outputTokens: 0, costUSD: 0),
            ]
        }
        func groups(_ rows: [CostUsageScanResult.DailyEntry]) -> [String: Set<String>] {
            rows.filter { $0.model != ScanEntry.messageBucketModel }
                .reduce(into: [:]) { $0["\($1.date) \($1.provider)", default: []].insert($1.model) }
        }
        let all = groups(entries)

        for hour in 0..<72 {
            let now = base.addingTimeInterval(Double(hour) * 3_600)
            let sent = groups(APIClient.dailyUsageRowsToUpload(entries, now: now))
            XCTAssertFalse(sent.isEmpty)
            for (group, models) in sent {
                XCTAssertEqual(
                    models, all[group],
                    "at \(now), \(group) was sent without some of its models; "
                        + "replace_daily_usage would delete them from the cloud")
            }
        }
    }

    // MARK: - Fixtures

    private static let now = ISO8601DateFormatter().date(from: "2026-10-03T09:00:00Z")!

    private static func scan() -> CostUsageScanResult {
        CostUsageScanResult(entries: [
            .init(date: DayKey.string(from: now), provider: "Claude", model: "claude-haiku-4-5",
                  inputTokens: 100, cachedTokens: 0, outputTokens: 5, costUSD: 0.01),
        ])
    }

    private func signedInAPI() async throws -> (APIClient, APIAuthorizationLease) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DailyUsageReplaceStubProtocol.self]
        let api = APIClient(
            token: nil,
            supabaseURL: "https://daily-usage.test",
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

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// Records every request and answers from `respond`. No delays: a stub that
/// sleeps in `startLoading` serializes every request behind it.
private final class DailyUsageReplaceStubProtocol: URLProtocol {
    typealias Responder = (URLRequest) -> (status: Int, body: String)

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

    static func clearRequests() {
        lock.lock(); defer { lock.unlock() }
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

        let (status, body) = responder?(copy) ?? (500, "{}")
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
#endif
