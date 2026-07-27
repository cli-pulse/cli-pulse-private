#if os(macOS)
import Foundation
import XCTest
@testable import CLIPulseCore

final class HelperProviderAccountAPITests: XCTestCase {
    override func setUp() {
        super.setUp()
        HelperProviderAccountAPIStub.reset()
    }

    override func tearDown() {
        HelperProviderAccountAPIStub.reset()
        super.tearDown()
    }

    func testHelperV2SyncUsesDeviceAuthAndSecretFreeAccountRows()
        async throws
    {
        HelperProviderAccountAPIStub.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/helper_sync_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let api = makeAPI()
        let observedAt = try XCTUnwrap(
            sharedISO8601Formatter.date(
                from: "2026-07-24T06:00:00Z"
            )
        )

        let synced = try await api.syncProviderAccountQuotas(
            config: Self.helperConfig,
            accounts: [Self.accountPayload],
            observedAt: observedAt
        )

        XCTAssertEqual(synced, 1)
        let request = try XCTUnwrap(
            HelperProviderAccountAPIStub.requests.first
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(
            root["p_device_id"] as? String,
            Self.helperConfig.deviceId
        )
        XCTAssertEqual(
            root["p_helper_secret"] as? String,
            Self.helperConfig.helperSecret
        )
        let rows = try XCTUnwrap(root["p_rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            row["account_id"] as? String,
            "11111111-1111-4111-8111-111111111111"
        )
        XCTAssertEqual(row["provider"] as? String, "Claude")
        XCTAssertEqual(row["account_label"] as? String, "Work")
        XCTAssertEqual(row["plan_type"] as? String, "Max 20x")
        XCTAssertEqual(
            row["plan_source"] as? String,
            "userConfirmed"
        )
        XCTAssertEqual(row["plan_confidence"] as? String, "high")
        XCTAssertEqual(row["remaining"] as? Int, 40)
        XCTAssertEqual(row["quota"] as? Int, 100)
        XCTAssertEqual(
            row["observed_at"] as? String,
            "2026-07-24T06:00:00Z"
        )
        XCTAssertNil(row["status"])
        XCTAssertNil(row["source_device_id"])

        let forbiddenProviderCredentialKeys = [
            "api_key", "cookie", "access_token", "refresh_token",
            "password",
        ]
        for key in recursiveKeys(in: rows) {
            XCTAssertFalse(
                forbiddenProviderCredentialKeys.contains {
                    key.lowercased().contains($0)
                },
                "helper account row contains provider credential key \(key)"
            )
        }
    }

    func testHelperV2SyncOmitsEmailShapedPlanEvidence()
        async throws
    {
        HelperProviderAccountAPIStub.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/helper_sync_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let email = "vertex-user@example.com"
        let account = HelperIPC.CollectorAccountPayload(
            accountID: Self.accountPayload.accountID,
            provider: ProviderKind.vertexAI.rawValue,
            accountLabel: "Personal",
            dataKind: .quota,
            usage: HelperIPC.CollectorUsagePayload(
                quota: 100,
                remaining: 40,
                todayUsage: 60,
                weekUsage: 60,
                statusText: "60% used",
                planType: email,
                resetTime: nil,
                tiers: []
            )
        )
        let observedAt = try XCTUnwrap(
            sharedISO8601Formatter.date(
                from: "2026-07-24T06:00:00Z"
            )
        )

        let synced = try await makeAPI().syncProviderAccountQuotas(
            config: Self.helperConfig,
            accounts: [account],
            observedAt: observedAt
        )

        XCTAssertEqual(synced, 1)
        let request = try XCTUnwrap(
            HelperProviderAccountAPIStub.requests.first
        )
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let rows = try XCTUnwrap(
            root["p_rows"] as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)

        XCTAssertNil(row["plan_type"])
        XCTAssertNil(row["plan_observed_at"])
        XCTAssertEqual(row["plan_source"] as? String, "unknown")
        XCTAssertEqual(
            row["plan_confidence"] as? String,
            "unavailable"
        )
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self).contains(email)
        )
    }

    func testHelperV2SyncOmitsCloudTextBeyondServerLimit()
        async throws
    {
        HelperProviderAccountAPIStub.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/helper_sync_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let oversized = String(repeating: "x", count: 121)
        let oversizedTierName =
            String(repeating: "t", count: 121)
        let tiers =
            [
                TierDTO(
                    name: oversizedTierName,
                    quota: 100,
                    remaining: 50
                ),
            ]
            + (0..<25).map {
                TierDTO(
                    name: "Window \($0)",
                    quota: 100,
                    remaining: 50,
                    reset_time:
                        $0 == 0 ? "not-a-timestamp" : nil
                )
            }
        let account = HelperIPC.CollectorAccountPayload(
            accountID: Self.accountPayload.accountID,
            provider: Self.accountPayload.provider,
            accountLabel: oversized,
            planOverride: oversized,
            dataKind: .quota,
            usage: HelperIPC.CollectorUsagePayload(
                quota: -100,
                remaining: -40,
                todayUsage: 60,
                weekUsage: 60,
                statusText: "60% used",
                planType: oversized,
                resetTime: "not-a-timestamp",
                tiers: tiers
            )
        )
        let observedAt = try XCTUnwrap(
            sharedISO8601Formatter.date(
                from: "2026-07-24T06:00:00Z"
            )
        )

        let synced = try await makeAPI().syncProviderAccountQuotas(
            config: Self.helperConfig,
            accounts: [account],
            observedAt: observedAt
        )

        XCTAssertEqual(synced, 1)
        let request = try XCTUnwrap(
            HelperProviderAccountAPIStub.requests.first
        )
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let rows = try XCTUnwrap(
            root["p_rows"] as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)

        XCTAssertNil(row["account_label"])
        XCTAssertNil(row["plan_type"])
        XCTAssertNil(row["plan_observed_at"])
        XCTAssertEqual(row["plan_source"] as? String, "unknown")
        XCTAssertEqual(
            row["plan_confidence"] as? String,
            "unavailable"
        )
        XCTAssertNil(row["remaining"])
        XCTAssertNil(row["quota"])
        XCTAssertNil(row["reset_time"])
        let uploadedTiers = try XCTUnwrap(
            row["tiers"] as? [[String: Any]]
        )
        XCTAssertEqual(uploadedTiers.count, 24)
        XCTAssertNil(uploadedTiers.first?["reset_time"])
        XCTAssertEqual(
            uploadedTiers.last?["name"] as? String,
            "Window 23"
        )
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self)
                .contains(oversized)
        )
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self)
                .contains(oversizedTierName)
        )
    }

    func testStatusOnlyRowsDoNotCreateQuotaAccounts() async throws {
        HelperProviderAccountAPIStub.handler = { request in
            XCTFail("status-only account must not call v2 quota RPC: \(request)")
            return .json("{}", status: 500)
        }
        let api = makeAPI()
        let statusOnly = HelperIPC.CollectorAccountPayload(
            accountID: Self.accountPayload.accountID,
            provider: Self.accountPayload.provider,
            accountLabel: Self.accountPayload.accountLabel,
            dataKind: .statusOnly,
            usage: Self.accountPayload.usage
        )

        let synced = try await api.syncProviderAccountQuotas(
            config: Self.helperConfig,
            accounts: [statusOnly],
            observedAt: Date()
        )

        XCTAssertEqual(synced, 0)
        XCTAssertTrue(HelperProviderAccountAPIStub.requests.isEmpty)
    }

    func testLegacyHelperQuotaPayloadOmitsLocalDiagnostics() throws {
        let email = "claude-user@example.com"
        let resourceHost = "customer-resource.openai.azure.com"
        let payload = HelperIPC.CollectorUsagePayload(
            quota: 100,
            remaining: 40,
            todayUsage: 12,
            weekUsage: 34,
            statusText:
                "Signed in as \(email) — Connect in Settings",
            planType: resourceHost,
            resetTime: "2026-07-24T08:00:00Z",
            tiers: []
        )

        let result = HelperAPIClient.legacyProviderTiers(
            from: ["Claude": payload]
        )
        let row = try XCTUnwrap(
            result["Claude"] as? [String: Any]
        )
        let encoded = try JSONSerialization.data(
            withJSONObject: result
        )

        XCTAssertNil(row["status_text"])
        XCTAssertNil(row["plan_type"])
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self).contains(email)
        )
        XCTAssertFalse(
            String(decoding: encoded, as: UTF8.self)
                .contains(resourceHost)
        )
    }

    func testLegacyHelperProjectionUsesOnlyPairedUsersAccounts()
        throws
    {
        let accountAID = UUID(
            uuidString:
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        )!
        let accountBID = UUID(
            uuidString:
                "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
        )!
        let accounts = [
            Self.accountPayload(
                id: accountAID,
                remaining: 90
            ),
            Self.accountPayload(
                id: accountBID,
                remaining: 25
            ),
        ]
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: accountAID,
                sortOrder: 0,
                syncOwnerUserID: "user-a"
            ),
            ProviderConfig(
                kind: .claude,
                accountID: accountBID,
                sortOrder: 1,
                syncOwnerUserID: "user-b"
            ),
        ]

        let result = HelperAPIClient.legacyProviderTiers(
            from: accounts,
            configs: configs,
            ownedBy: " USER-B "
        )
        let row = try XCTUnwrap(
            result[ProviderKind.claude.rawValue]
                as? [String: Any]
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(row["remaining"] as? Int, 25)
    }

    private func makeAPI() -> HelperAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [
            HelperProviderAccountAPIStub.self,
        ]
        return HelperAPIClient(
            supabaseURL: "https://helper-account.test",
            anonKey: "anon-key",
            session: URLSession(configuration: configuration)
        )
    }

    private func recursiveKeys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { key, child in
                [key] + recursiveKeys(in: child)
            }
        }
        if let array = value as? [Any] {
            return array.flatMap(recursiveKeys)
        }
        return []
    }

    private static let helperConfig = HelperConfig(
        deviceId: "22222222-2222-4222-8222-222222222222",
        userId: "33333333-3333-4333-8333-333333333333",
        deviceName: "Test Mac",
        helperVersion: "test",
        helperSecret: "device-secret"
    )

    private static let accountPayload =
        HelperIPC.CollectorAccountPayload(
            accountID: UUID(
                uuidString:
                    "11111111-1111-4111-8111-111111111111"
            )!,
            provider: "Claude",
            accountLabel: "Work",
            planOverride: "Max 20x",
            dataKind: .quota,
            usage: HelperIPC.CollectorUsagePayload(
                quota: 100,
                remaining: 40,
                todayUsage: 12,
                weekUsage: 34,
                statusText: "60% used",
                planType: "Max",
                resetTime: "2026-07-24T08:00:00Z",
                tiers: [
                    TierDTO(
                        name: "5h Window",
                        quota: 100,
                        remaining: 40,
                        reset_time: "2026-07-24T08:00:00Z",
                        windowMinutes: 300,
                        role: .primary
                    ),
                ]
            )
        )

    private static func accountPayload(
        id: UUID,
        remaining: Int
    ) -> HelperIPC.CollectorAccountPayload {
        HelperIPC.CollectorAccountPayload(
            accountID: id,
            provider: ProviderKind.claude.rawValue,
            accountLabel: nil,
            dataKind: .quota,
            usage: HelperIPC.CollectorUsagePayload(
                quota: 100,
                remaining: remaining,
                todayUsage: 100 - remaining,
                weekUsage: 100 - remaining,
                statusText: nil,
                planType: nil,
                resetTime: nil,
                tiers: []
            )
        )
    }
}

private final class HelperProviderAccountAPIStub: URLProtocol {
    struct StubResponse {
        let status: Int
        let body: Data

        static func json(
            _ value: String,
            status: Int = 200
        ) -> StubResponse {
            StubResponse(status: status, body: Data(value.utf8))
        }
    }

    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> StubResponse)?
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(
        for request: URLRequest
    ) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorded = Self.materialized(request)
        Self.lock.lock()
        Self.requests.append(recorded)
        let handler = Self.handler
        Self.lock.unlock()
        do {
            let stub = try XCTUnwrap(handler)(recorded)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: [
                    "Content-Type": "application/json",
                ]
            )!
            client?.urlProtocol(
                self,
                didReceive: response,
                cacheStoragePolicy: .notAllowed
            )
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func materialized(
        _ request: URLRequest
    ) -> URLRequest {
        guard
            request.httpBody == nil,
            let stream = request.httpBodyStream
        else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(
                &buffer,
                maxLength: buffer.count
            )
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}
#endif
