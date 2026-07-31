#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class HelperProviderAccountsIPCTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_774_065_600)

    func testV1ProviderDictionaryMapsToExistingLegacyAccount() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            sortOrder: 0,
            accountLabel: "Legacy"
        )
        let data = Data("""
        {
          "timestamp": "2026-03-21T04:00:00Z",
          "providers": {
            "Claude": {
              "quota": 100,
              "remaining": 64,
              "today_usage": 36,
              "week_usage": 52,
              "plan_type": "Pro",
              "status_text": "36% used",
              "tiers": []
            }
          }
        }
        """.utf8)

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [config],
            now: now
        )

        XCTAssertEqual(snapshot.providerResults.count, 1)
        XCTAssertEqual(snapshot.accountResults.count, 1)
        XCTAssertEqual(snapshot.accountResults.first?.accountID, accountID)
        XCTAssertEqual(snapshot.accountResults.first?.result.usage.remaining, 64)
    }

    func testV1DisabledProviderProjectionIsRejected() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "77777777-7777-4777-8777-777777777777"))
        let data = Data("""
        {
          "timestamp": "2026-03-21T04:00:00Z",
          "providers": {
            "Claude": {
              "quota": 100,
              "remaining": 50,
              "tiers": []
            }
          }
        }
        """.utf8)
        let disabledConfig = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            isEnabled: false
        )

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [disabledConfig],
            now: now
        )

        XCTAssertTrue(snapshot.accountResults.isEmpty)
        XCTAssertTrue(snapshot.providerResults.isEmpty)
    }

    func testUnwrappedV1ProviderDictionaryStillDecodes() {
        let data = Data("""
        {
          "Codex": {
            "quota": 100,
            "remaining": 82,
            "status_text": "18% used",
            "tiers": []
          }
        }
        """.utf8)

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [],
            now: now
        )

        XCTAssertEqual(snapshot.providerResults.count, 1)
        XCTAssertEqual(snapshot.providerResults.first?.usage.provider, ProviderKind.codex.rawValue)
        XCTAssertEqual(snapshot.providerResults.first?.usage.remaining, 82)
    }

    func testV2KeepsTwoAccountsForSameProviderAndOneCompatibilityProjection() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let secondID = try XCTUnwrap(UUID(uuidString: "33333333-3333-4333-8333-333333333333"))
        let first = HelperIPC.CollectorAccountPayload(
            accountID: firstID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: "Work",
            dataKind: .quota,
            usage: makeUsage(remaining: 75)
        )
        let second = HelperIPC.CollectorAccountPayload(
            accountID: secondID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: "Personal",
            dataKind: .quota,
            usage: makeUsage(remaining: 35)
        )
        let envelope = HelperIPC.CollectorResultsEnvelopeV2(
            timestamp: "2026-03-21T04:00:00Z",
            accounts: [first, second],
            providers: [ProviderKind.claude.rawValue: first.usage]
        )
        let data = try HelperIPC.encodeCollectorResultsV2(envelope)
        let legacyRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let legacyProviders = try XCTUnwrap(
            legacyRoot["providers"] as? [String: Any]
        )
        let configs = [
            ProviderConfig(kind: .claude, accountID: firstID, sortOrder: 0, accountLabel: "Work"),
            ProviderConfig(kind: .claude, accountID: secondID, sortOrder: 1, accountLabel: "Personal"),
        ]

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: configs,
            now: now
        )

        XCTAssertEqual(snapshot.accountResults.count, 2)
        XCTAssertEqual(Set(snapshot.accountResults.map(\.accountID)), Set([firstID, secondID]))
        XCTAssertEqual(snapshot.providerResults.count, 1)
        XCTAssertEqual(snapshot.providerResults.first?.usage.remaining, 75)
        XCTAssertNotNil(
            legacyProviders[ProviderKind.claude.rawValue],
            "A v1 main app must still see the provider projection in a v2 helper payload"
        )
    }

    func testStaleV2EnvelopeIsRejected() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "44444444-4444-4444-8444-444444444444"))
        let envelope = HelperIPC.CollectorResultsEnvelopeV2(
            timestamp: "2026-03-21T03:50:00Z",
            accounts: [
                HelperIPC.CollectorAccountPayload(
                    accountID: accountID,
                    provider: ProviderKind.claude.rawValue,
                    accountLabel: nil,
                    dataKind: .quota,
                    usage: makeUsage(remaining: 50)
                ),
            ],
            providers: nil
        )
        let data = try HelperIPC.encodeCollectorResultsV2(envelope)

        XCTAssertThrowsError(
            try HelperIPC.decodeCollectorResults(data, now: now)
        ) { error in
            XCTAssertEqual(
                error as? HelperIPC.CollectorResultsError,
                .stale
            )
        }
        XCTAssertTrue(
            DataRefreshManager.parseHelperCollectorResults(
                data,
                providerConfigs: [],
                now: now
            ).accountResults.isEmpty
        )
    }

    func testV2DoesNotResurrectDisabledAccountFromFreshHelperCache() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "66666666-6666-4666-8666-666666666666"))
        let account = HelperIPC.CollectorAccountPayload(
            accountID: accountID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: "Disabled",
            dataKind: .quota,
            usage: makeUsage(remaining: 50)
        )
        let data = try HelperIPC.encodeCollectorResultsV2(
            HelperIPC.CollectorResultsEnvelopeV2(
                timestamp: "2026-03-21T04:00:00Z",
                accounts: [account],
                providers: [ProviderKind.claude.rawValue: account.usage]
            )
        )
        let disabledConfig = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            isEnabled: false
        )

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [disabledConfig],
            now: now
        )

        XCTAssertTrue(snapshot.accountResults.isEmpty)
        XCTAssertTrue(snapshot.providerResults.isEmpty)
    }

    func testV2DeletedAccountProjectionDoesNotLeakThroughAnotherEnabledAccount() throws {
        let deletedID = try XCTUnwrap(UUID(uuidString: "88888888-8888-4888-8888-888888888888"))
        let enabledID = try XCTUnwrap(UUID(uuidString: "99999999-9999-4999-8999-999999999999"))
        let deletedAccount = HelperIPC.CollectorAccountPayload(
            accountID: deletedID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: "Deleted",
            dataKind: .quota,
            usage: makeUsage(remaining: 10)
        )
        let data = try HelperIPC.encodeCollectorResultsV2(
            HelperIPC.CollectorResultsEnvelopeV2(
                timestamp: "2026-03-21T04:00:00Z",
                accounts: [deletedAccount],
                providers: [ProviderKind.claude.rawValue: deletedAccount.usage]
            )
        )
        let currentConfig = ProviderConfig(
            kind: .claude,
            accountID: enabledID,
            isEnabled: true
        )

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [currentConfig],
            now: now
        )

        XCTAssertTrue(snapshot.accountResults.isEmpty)
        XCTAssertTrue(snapshot.providerResults.isEmpty)
    }

    func testV2PreservesUnknownQuotaAndCollectorMetadata() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"))
        let metadata = HelperIPC.CollectorMetadataPayload(
            displayName: "OpenRouter",
            category: "aggregator",
            supportsExactCost: true,
            supportsQuota: true,
            defaultQuota: nil
        )
        let usage = HelperIPC.CollectorUsagePayload(
            quota: nil,
            remaining: nil,
            todayUsage: 12,
            weekUsage: 34,
            statusText: "Credits available",
            planType: nil,
            resetTime: nil,
            tiers: [],
            metadata: metadata
        )
        let account = HelperIPC.CollectorAccountPayload(
            accountID: accountID,
            provider: ProviderKind.openRouter.rawValue,
            accountLabel: nil,
            dataKind: .credits,
            usage: usage
        )
        let data = try HelperIPC.encodeCollectorResultsV2(
            HelperIPC.CollectorResultsEnvelopeV2(
                timestamp: "2026-03-21T04:00:00Z",
                accounts: [account],
                providers: [ProviderKind.openRouter.rawValue: usage]
            )
        )
        let config = ProviderConfig(kind: .openRouter, accountID: accountID)

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [config],
            now: now
        )
        let bridged = try XCTUnwrap(snapshot.providerResults.first?.usage)

        XCTAssertNil(bridged.quota)
        XCTAssertNil(bridged.remaining)
        XCTAssertEqual(bridged.metadata?.display_name, "OpenRouter")
        XCTAssertEqual(bridged.metadata?.category, "aggregator")
        XCTAssertEqual(bridged.metadata?.supports_exact_cost, true)
        XCTAssertEqual(bridged.metadata?.supports_quota, true)
    }

    func testV2HelperTimestampBecomesAccountObservationTime() throws {
        let accountID = try XCTUnwrap(UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"))
        let account = HelperIPC.CollectorAccountPayload(
            accountID: accountID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: nil,
            planDetectionStartedAt:
                Date(timeIntervalSince1970: 1_774_065_300),
            dataKind: .quota,
            usage: makeUsage(remaining: 50)
        )
        let data = try HelperIPC.encodeCollectorResultsV2(
            HelperIPC.CollectorResultsEnvelopeV2(
                timestamp: "2026-03-21T03:56:00Z",
                accounts: [account],
                providers: nil
            )
        )
        let config = ProviderConfig(kind: .claude, accountID: accountID)
        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [config],
            now: now
        )

        let accountUsage = try XCTUnwrap(
            DataRefreshManager.accountUsages(from: snapshot.accountResults, observedAt: now).first
        )

        XCTAssertEqual(
            accountUsage.observedAt,
            "2026-03-21T03:56:00.000Z"
        )
        XCTAssertEqual(
            accountUsage.planEvidence.observedAt,
            Date(timeIntervalSince1970: 1_774_065_300),
            "detected plan revision must preserve the per-account collection start while quota freshness uses envelope completion"
        )
    }

    func testOldV2WithoutCollectionStartCannotOverrideLaterManualClear()
        throws
    {
        let accountID = try XCTUnwrap(
            UUID(
                uuidString:
                    "bcbcbcbc-bcbc-4bcb-8bcb-bcbcbcbcbcbc"
            )
        )
        let manualClearAt = try XCTUnwrap(
            sharedISO8601Parse("2026-03-21T03:55:00.000Z")
        )
        let account = HelperIPC.CollectorAccountPayload(
            accountID: accountID,
            provider: ProviderKind.claude.rawValue,
            accountLabel: nil,
            planDetectionStartedAt: nil,
            dataKind: .quota,
            usage: HelperIPC.CollectorUsagePayload(
                quota: 100,
                remaining: 50,
                todayUsage: 50,
                weekUsage: 50,
                statusText: nil,
                planType: "Stale Detected Pro",
                resetTime: nil,
                tiers: []
            )
        )
        let data = try HelperIPC.encodeCollectorResultsV2(
            HelperIPC.CollectorResultsEnvelopeV2(
                timestamp: "2026-03-21T03:56:00Z",
                accounts: [account],
                providers: nil
            )
        )
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            planOverride: nil,
            planOverrideUpdatedAt: manualClearAt
        )

        let snapshot = DataRefreshManager
            .parseHelperCollectorResults(
                data,
                providerConfigs: [config],
                now: now
            )
        let accountUsage = try XCTUnwrap(
            DataRefreshManager.accountUsages(
                from: snapshot.accountResults,
                observedAt: now
            ).first
        )

        XCTAssertNil(accountUsage.planEvidence.rawValue)
        XCTAssertEqual(
            accountUsage.planEvidence.source,
            .userConfirmed
        )
        XCTAssertEqual(
            accountUsage.planEvidence.observedAt,
            manualClearAt,
            "an old helper completion timestamp must not make stale detected plan evidence newer than a manual clear"
        )
        XCTAssertEqual(
            accountUsage.observedAt,
            "2026-03-21T03:56:00.000Z",
            "quota freshness still uses the helper envelope completion"
        )
    }

    func testStaleV1EnvelopeRemainsRejected() {
        let data = Data("""
        {
          "timestamp": "2026-03-21T03:50:00Z",
          "providers": {
            "Claude": {
              "quota": 100,
              "remaining": 50,
              "tiers": []
            }
          }
        }
        """.utf8)

        let snapshot = DataRefreshManager.parseHelperCollectorResults(
            data,
            providerConfigs: [],
            now: now
        )

        XCTAssertTrue(snapshot.providerResults.isEmpty)
        XCTAssertTrue(snapshot.accountResults.isEmpty)
    }

    func testMalformedV1TimestampIsRejected() {
        let data = Data("""
        {
          "timestamp": "not-a-date",
          "providers": {
            "Claude": {
              "quota": 100,
              "remaining": 50,
              "tiers": []
            }
          }
        }
        """.utf8)

        XCTAssertThrowsError(
            try HelperIPC.decodeCollectorResults(data, now: now)
        ) { error in
            XCTAssertEqual(
                error as? HelperIPC.CollectorResultsError,
                .invalidTimestamp
            )
        }
    }

    func testV2PayloadContainsNoProviderSecrets() throws {
        let secretAPIKey = "sk-secret-value-that-must-not-cross-ipc"
        let secretCookie = "session=private-cookie-value"
        var config = ProviderConfig(
            kind: .claude,
            accountID: try XCTUnwrap(UUID(uuidString: "55555555-5555-4555-8555-555555555555")),
            apiKey: secretAPIKey,
            manualCookieHeader: secretCookie,
            accountLabel: "Work"
        )
        config.planOverride = "Max 20x"
        let envelope = HelperIPC.CollectorResultsEnvelopeV2(
            timestamp: "2026-03-21T04:00:00Z",
            accounts: [
                HelperIPC.CollectorAccountPayload(
                    accountID: config.accountID,
                    provider: config.kind.rawValue,
                    accountLabel: config.accountLabel,
                    dataKind: .quota,
                    usage: makeUsage(remaining: 50)
                ),
            ],
            providers: nil
        )

        let data = try HelperIPC.encodeCollectorResultsV2(envelope)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(json.contains(secretAPIKey))
        XCTAssertFalse(json.contains(secretCookie))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("apiKey"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("cookie"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("accessToken"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("refreshToken"))
        XCTAssertFalse(json.localizedCaseInsensitiveContains("\"token\""))
    }

    private func makeUsage(remaining: Int) -> HelperIPC.CollectorUsagePayload {
        HelperIPC.CollectorUsagePayload(
            quota: 100,
            remaining: remaining,
            todayUsage: 100 - remaining,
            weekUsage: 100 - remaining,
            statusText: "\(100 - remaining)% used",
            planType: "Max",
            resetTime: nil,
            tiers: [],
            metadata: nil
        )
    }
}
#endif
