import Foundation
import XCTest
@testable import CLIPulseCore

final class ProviderAccountAPITests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProviderAccountAPIStubProtocol.reset()
    }

    override func tearDown() {
        ProviderAccountAPIStubProtocol.reset()
        super.tearDown()
    }

    func testOlderExternalAuthTransitionCannotReplaceNewerSession() async {
        let api = makeAPI(
            flags: .init(readV2: true, writeV2: true)
        )

        let beganA = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        let installedA = await api.installExternalAuthenticatedSession(
            accessToken: "token-a",
            refreshToken: "refresh-a",
            userID: "user-a",
            transitionGeneration: 1
        )
        let beganB = await api.beginExternalAuthorizationTransition(
            generation: 2
        )
        let installedB = await api.installExternalAuthenticatedSession(
            accessToken: "token-b",
            refreshToken: "refresh-b",
            userID: "user-b",
            transitionGeneration: 2
        )

        let installedLateA =
            await api.installExternalAuthenticatedSession(
                accessToken: "late-token-a",
                refreshToken: "late-refresh-a",
                userID: "user-a",
                transitionGeneration: 1
            )
        XCTAssertTrue(beganA)
        XCTAssertTrue(installedA)
        XCTAssertTrue(beganB)
        XCTAssertTrue(installedB)
        XCTAssertFalse(
            installedLateA
        )
        let currentToken = await api.getToken()
        let currentUserID = await api.userId
        XCTAssertEqual(currentToken, "token-b")
        XCTAssertEqual(currentUserID, "user-b")
    }

    func testAuthorizationLeaseRequiresExpectedUser() async {
        let api = makeAPI(
            flags: .init(readV2: true, writeV2: true)
        )
        _ = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a",
            refreshToken: "refresh-a",
            userID: "user-a",
            transitionGeneration: 1
        )

        let matching = await api.authorizationLease(
            expectedUserID: "user-a"
        )
        let mismatched = await api.authorizationLease(
            expectedUserID: "user-b"
        )

        XCTAssertNotNil(matching)
        XCTAssertNil(
            mismatched,
            "an account-A mutation must not acquire an account-B lease"
        )
    }

    func testStaleSignOutRevokesOldTokenWithoutClearingNewSession() async {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/auth/v1/logout")
            XCTAssertEqual(
                request.value(
                    forHTTPHeaderField: "Authorization"
                ),
                "Bearer token-a"
            )
            return .json("{}")
        }
        let api = makeAPI(
            flags: .init(readV2: true, writeV2: true)
        )
        _ = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-a",
            refreshToken: "refresh-a",
            userID: "user-a",
            transitionGeneration: 1
        )
        _ = await api.beginExternalAuthorizationTransition(
            generation: 2
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "token-b",
            refreshToken: "refresh-b",
            userID: "user-b",
            transitionGeneration: 2
        )

        await api.signOutServer(
            expectedAccessToken: "token-a"
        )

        let currentToken = await api.getToken()
        let currentUserID = await api.userId
        XCTAssertEqual(currentToken, "token-b")
        XCTAssertEqual(currentUserID, "user-b")
    }

    func testStatusWritesCommitInInvocationOrder() async throws {
        let recorder = ProviderAccountStatusDeliveryRecorder()
        let firstRequestStarted = expectation(
            description: "disabled status request started"
        )
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/set_provider_account_statuses"
            )
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any]
            )
            let rows = try XCTUnwrap(
                object["p_rows"] as? [[String: Any]]
            )
            let status = try XCTUnwrap(
                rows.first?["status"] as? String
            )
            if status == "disabled" {
                firstRequestStarted.fulfill()
            }
            return .json(
                #"{"accounts_updated":1}"#,
                delay: status == "disabled" ? 0.15 : 0,
                onDeliver: {
                    recorder.append(status)
                }
            )
        }

        let api = makeAPI(
            flags: .init(readV2: true, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        let accountID = Self.accountUsage.id

        let disable = Task {
            await api.syncProviderAccountStatuses(
                [
                    ProviderAccountStatusUpdate(
                        accountID: accountID,
                        provider: .claude,
                        isEnabled: false
                    ),
                ],
                authorizationLease: lease
            )
        }
        await fulfillment(of: [firstRequestStarted], timeout: 2)
        let enable = Task {
            await api.syncProviderAccountStatuses(
                [
                    ProviderAccountStatusUpdate(
                        accountID: accountID,
                        provider: .claude,
                        isEnabled: true
                    ),
                ],
                authorizationLease: lease
            )
        }

        let disableResult = await disable.value
        let enableResult = await enable.value

        XCTAssertTrue(disableResult)
        XCTAssertTrue(enableResult)
        XCTAssertEqual(
            recorder.values,
            ["disabled", "active"],
            "the final cloud status must match the latest user action"
        )
    }

    func testOlderLogicalStatusMutationIsRejectedWhenTasksArriveReversed()
        async throws
    {
        let recorder = ProviderAccountStatusDeliveryRecorder()
        ProviderAccountAPIStubProtocol.handler = { request in
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: body)
                    as? [String: Any]
            )
            let rows = try XCTUnwrap(
                object["p_rows"] as? [[String: Any]]
            )
            let status = try XCTUnwrap(
                rows.first?["status"] as? String
            )
            recorder.append(status)
            return .json(#"{"accounts_updated":1}"#)
        }

        let api = makeAPI(
            flags: .init(readV2: true, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        let accountID = Self.accountUsage.id

        let newest = await api.syncProviderAccountStatuses(
            [
                ProviderAccountStatusUpdate(
                    accountID: accountID,
                    provider: .claude,
                    isEnabled: true
                ),
            ],
            mutationRevision: 2,
            authorizationLease: lease
        )
        let delayedOlder = await api.syncProviderAccountStatuses(
            [
                ProviderAccountStatusUpdate(
                    accountID: accountID,
                    provider: .claude,
                    isEnabled: false
                ),
            ],
            mutationRevision: 1,
            authorizationLease: lease
        )

        XCTAssertTrue(newest)
        XCTAssertFalse(delayedOlder)
        XCTAssertEqual(
            recorder.values,
            ["active"],
            "task scheduling must not let an older user action win"
        )
    }

    func testV2SummaryDecodesTwoAccountsWithoutDuplicatingProviderCost() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/provider_account_summary")
            return .json(Self.v2SummaryJSON)
        }

        let api = makeAPI(flags: .init(readV2: true, writeV2: false))
        let result = try await api.providerAccountSummary()

        XCTAssertFalse(result.usedLegacyFallback)
        XCTAssertEqual(result.providers.count, 1)
        XCTAssertEqual(result.providerAccounts.count, 2)
        XCTAssertEqual(result.providers[0].provider, "Claude")
        XCTAssertEqual(result.providers[0].estimated_cost_today, 1.25)
        XCTAssertEqual(result.providers[0].estimated_cost_week, 7.5)
        XCTAssertEqual(result.providers[0].estimated_cost_30_day, 9.75)
        XCTAssertEqual(result.providers[0].quota, 100)
        XCTAssertEqual(result.providers[0].remaining, 20)
        XCTAssertEqual(result.providers[0].plan_type, "Multiple accounts")

        let work = try XCTUnwrap(
            result.providerAccounts.first {
                $0.id.uuidString.lowercased()
                    == "11111111-1111-4111-8111-111111111111"
            }
        )
        XCTAssertEqual(work.accountLabel, "Work")
        XCTAssertEqual(work.planEvidence.source, .providerAPI)
        XCTAssertEqual(work.planEvidence.confidence, .high)
        XCTAssertEqual(
            work.observedAt,
            "2026-07-24T01:01:00Z",
            "account freshness must come from observed_at, not updated_at"
        )
        XCTAssertEqual(
            work.planEvidence.observedAt,
            sharedISO8601Parse("2026-07-24T00:59:00Z")
        )

        // Cost exists exactly once on the provider row. Account rows carry
        // quota/freshness only, so two accounts cannot double the provider cost.
        XCTAssertEqual(
            result.providers.reduce(0) { $0 + $1.estimated_cost_today },
            1.25
        )
    }

    func testMissingV2RPCFallsBackToLegacyProviderSummary() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            switch request.url?.path {
            case "/rest/v1/rpc/provider_account_summary":
                return .json(
                    #"{"code":"PGRST202","message":"Could not find public.provider_account_summary(p_user_today) in the schema cache"}"#,
                    status: 404
                )
            case "/rest/v1/rpc/provider_summary":
                return .json(Self.legacySummaryJSON)
            default:
                XCTFail("unexpected request \(request.url?.absoluteString ?? "nil")")
                return .json("{}", status: 500)
            }
        }

        let api = makeAPI(flags: .init(readV2: true, writeV2: false))
        let result = try await api.providerAccountSummary()

        XCTAssertTrue(result.usedLegacyFallback)
        XCTAssertTrue(result.providerAccounts.isEmpty)
        XCTAssertEqual(result.providers.map(\.provider), ["Claude"])
        XCTAssertEqual(result.providers[0].remaining, 44)
        XCTAssertEqual(
            ProviderAccountAPIStubProtocol.requestPaths(),
            [
                "/rest/v1/rpc/provider_account_summary",
                "/rest/v1/rpc/provider_summary",
            ]
        )
    }

    func testReadFlagOffSkipsV2WhileWriteFlagRemainsIndependent() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/rest/v1/rpc/provider_summary")
            return .json(Self.legacySummaryJSON)
        }

        let api = makeAPI(flags: .init(readV2: false, writeV2: true))
        let result = try await api.providerAccountSummary()

        XCTAssertTrue(result.usedLegacyFallback)
        XCTAssertEqual(
            ProviderAccountAPIStubProtocol.requestPaths(),
            ["/rest/v1/rpc/provider_summary"]
        )
    }

    func testNonMissingV2ServerErrorDoesNotSilentlyFallback() async {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/provider_account_summary"
            )
            return .json(
                #"{"code":"XX000","message":"unexpected database failure"}"#,
                status: 500
            )
        }

        let api = makeAPI(flags: .init(readV2: true, writeV2: false))
        do {
            _ = try await api.providerAccountSummary()
            XCTFail("non-missing v2 failures must be surfaced")
        } catch {
            XCTAssertEqual(
                error as? APIError,
                .httpError(
                    status: 500,
                    body: #"{"code":"XX000","message":"unexpected database failure"}"#
                )
            )
        }

        XCTAssertEqual(
            ProviderAccountAPIStubProtocol.requestPaths(),
            ["/rest/v1/rpc/provider_account_summary"]
        )
    }

    func test404ForDifferentPostgRESTErrorDoesNotSilentlyFallback() async {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/provider_account_summary"
            )
            return .json(
                """
                {
                  "code": "PGRST116",
                  "message": "provider_account_summary returned no rows"
                }
                """,
                status: 404
            )
        }

        let api = makeAPI(flags: .init(readV2: true, writeV2: false))
        do {
            _ = try await api.providerAccountSummary()
            XCTFail("only a missing PGRST202 RPC may use the legacy fallback")
        } catch {
            guard case let .httpError(status, _) = error as? APIError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(status, 404)
        }

        XCTAssertEqual(
            ProviderAccountAPIStubProtocol.requestPaths(),
            ["/rest/v1/rpc/provider_account_summary"]
        )
    }

    func testReadAndWriteFlagsLoadFromIndependentDefaultsKeys() {
        let suiteName = "ProviderAccountAPITests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(
            true,
            forKey: ProviderAccountFeatureFlags.readDefaultsKey
        )
        defaults.set(
            false,
            forKey: ProviderAccountFeatureFlags.writeDefaultsKey
        )
        XCTAssertEqual(
            ProviderAccountFeatureFlags.load(from: defaults),
            .init(readV2: true, writeV2: false)
        )

        defaults.set(
            false,
            forKey: ProviderAccountFeatureFlags.readDefaultsKey
        )
        defaults.set(
            true,
            forKey: ProviderAccountFeatureFlags.writeDefaultsKey
        )
        XCTAssertEqual(
            ProviderAccountFeatureFlags.load(from: defaults),
            .init(readV2: false, writeV2: true)
        )
    }

    func testLocalAccountSnapshotReplacesOnlyMatchingCloudAccount() {
        let matchingID = UUID(
            uuidString: "55555555-5555-4555-8555-555555555555"
        )!
        let cloudOnlyID = UUID(
            uuidString: "66666666-6666-4666-8666-666666666666"
        )!
        let cloud = [
            Self.usage(
                id: matchingID,
                label: "Work",
                remaining: 80,
                observedAt: "2026-07-24T02:00:00Z"
            ),
            Self.usage(
                id: cloudOnlyID,
                label: "Personal",
                remaining: 20,
                observedAt: "2026-07-24T02:01:00Z"
            ),
        ]
        let local = [
            Self.usage(
                id: matchingID,
                label: "Work",
                remaining: 60,
                observedAt: "2026-07-24T03:00:00Z"
            ),
        ]

        let merged = DataRefreshManager.mergeProviderAccounts(
            cloud: cloud,
            local: local
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(
            merged.first(where: { $0.id == matchingID })?.remaining,
            60
        )
        XCTAssertEqual(
            merged.first(where: { $0.id == matchingID })?.observedAt,
            "2026-07-24T03:00:00Z"
        )
        XCTAssertEqual(
            merged.first(where: { $0.id == cloudOnlyID })?.remaining,
            20
        )
    }

    func testOlderLocalAccountSnapshotCannotReplaceNewerCloudAccount() {
        let accountID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let cloud = Self.usage(
            id: accountID,
            label: "Work",
            remaining: 25,
            observedAt: "2026-07-24T04:00:00Z"
        )
        let local = Self.usage(
            id: accountID,
            label: "Work",
            remaining: 75,
            observedAt: "2026-07-24T03:00:00Z"
        )

        let merged = DataRefreshManager.mergeProviderAccounts(
            cloud: [cloud],
            local: [local]
        )

        XCTAssertEqual(merged.first?.remaining, 25)
        XCTAssertEqual(merged.first?.observedAt, "2026-07-24T04:00:00Z")
    }

    func testNewerLocalQuotaCannotEraseNewerCloudPlanEvidence() throws {
        let accountID = UUID(
            uuidString: "88888888-8888-4888-8888-888888888888"
        )!
        let cloud = Self.usage(
            id: accountID,
            label: "Cloud label",
            remaining: 25,
            observedAt: "2026-07-24T04:00:00Z",
            planRawValue: "pro",
            planObservedAt: "2026-07-24T05:00:00Z"
        )
        let local = Self.usage(
            id: accountID,
            label: "Local label",
            remaining: 75,
            observedAt: "2026-07-24T06:00:00Z",
            planRawValue: nil,
            planObservedAt: nil
        )

        let merged = try XCTUnwrap(
            DataRefreshManager.mergeProviderAccounts(
                cloud: [cloud],
                local: [local]
            ).first
        )

        XCTAssertEqual(merged.remaining, 75)
        XCTAssertEqual(merged.accountLabel, "Local label")
        XCTAssertEqual(merged.observedAt, "2026-07-24T06:00:00Z")
        XCTAssertEqual(merged.planEvidence.rawValue, "pro")
        XCTAssertEqual(
            merged.planEvidence.observedAt,
            sharedISO8601Parse("2026-07-24T05:00:00Z")
        )
    }

    func testNewerLocalPlanSurvivesOlderLocalQuotaSnapshot() throws {
        let accountID = UUID(
            uuidString: "99999999-9999-4999-8999-999999999999"
        )!
        let cloud = Self.usage(
            id: accountID,
            label: "Cloud label",
            remaining: 25,
            observedAt: "2026-07-24T06:00:00Z",
            planRawValue: "pro",
            planObservedAt: "2026-07-24T04:00:00Z"
        )
        let local = Self.usage(
            id: accountID,
            label: "Local label",
            remaining: 75,
            observedAt: "2026-07-24T05:00:00Z",
            planRawValue: "max",
            planObservedAt: "2026-07-24T07:00:00Z"
        )

        let merged = try XCTUnwrap(
            DataRefreshManager.mergeProviderAccounts(
                cloud: [cloud],
                local: [local]
            ).first
        )

        XCTAssertEqual(merged.remaining, 25)
        XCTAssertEqual(merged.accountLabel, "Cloud label")
        XCTAssertEqual(merged.observedAt, "2026-07-24T06:00:00Z")
        XCTAssertEqual(merged.planEvidence.rawValue, "max")
        XCTAssertEqual(
            merged.planEvidence.observedAt,
            sharedISO8601Parse("2026-07-24T07:00:00Z")
        )
    }

    #if os(macOS)
    func testV2WriteBodyContainsNoProviderSecretsOrCostFields() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/upsert_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }

        let api = makeAPI(flags: .init(readV2: false, writeV2: true))
        let lease = try await requireAuthorizationLease(for: api)
        await api.syncProviderAccountQuotas(
            [Self.accountUsage],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try XCTUnwrap(object as? [String: Any])
        let rows = try XCTUnwrap(root["p_rows"] as? [[String: Any]])
        let row = try XCTUnwrap(rows.first)

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            row["account_id"] as? String,
            "33333333-3333-4333-8333-333333333333"
        )
        XCTAssertEqual(
            row["observed_at"] as? String,
            "2026-07-24T03:00:00.000Z"
        )
        XCTAssertEqual(
            Set(row.keys),
            [
                "account_id", "provider", "account_label",
                "plan_type", "plan_source", "plan_confidence",
                "plan_observed_at", "remaining", "quota",
                "reset_time", "tiers", "observed_at", "source_device_id",
            ]
        )

        let forbiddenFragments = [
            "token", "cookie", "secret", "password", "api_key", "cost",
        ]
        for key in Self.recursiveKeys(in: object) {
            XCTAssertFalse(
                forbiddenFragments.contains {
                    key.lowercased().contains($0)
                },
                "provider-account uplink contains forbidden key \(key)"
            )
        }
    }

    func testV2WriteOmitsExternalIdentifiersFromPlanEvidence()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/upsert_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let email = "vertex-user@example.com"
        let resourceHost = "customer-resource.openai.azure.com"
        let account = ProviderAccountUsage(
            id: Self.accountUsage.id,
            provider: .vertexAI,
            accountLabel: "Personal",
            planEvidence: ProviderPlanEvidence(
                rawValue: email,
                displayValue: resourceHost,
                source: .accountMetadata,
                confidence: .high,
                observedAt: sharedISO8601Parse(
                    "2026-07-24T02:59:00Z"
                )
            ),
            quota: 100,
            remaining: 60,
            tiers: [],
            resetTime: nil,
            observedAt: "2026-07-24T03:00:00Z",
            sourceDeviceID: nil,
            statusText: "40% used"
        )

        let api = makeAPI(
            flags: .init(readV2: false, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        await api.syncProviderAccountQuotas(
            [account],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
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
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self)
                .contains(resourceHost)
        )
    }

    func testV2WriteEncodesExplicitPlanClearWithFreshRevision()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/upsert_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let clearedAt = try XCTUnwrap(
            sharedISO8601Parse("2026-07-24T02:59:00.125Z")
        )
        let account = ProviderAccountUsage(
            id: Self.accountUsage.id,
            provider: .claude,
            accountLabel: "Work",
            planEvidence: ProviderPlanEvidence(
                rawValue: nil,
                displayValue: nil,
                source: .userConfirmed,
                confidence: .high,
                observedAt: clearedAt
            ),
            quota: 100,
            remaining: 60,
            tiers: [],
            resetTime: nil,
            observedAt: "2026-07-24T03:00:00.250Z",
            sourceDeviceID: nil,
            statusText: "40% used"
        )
        let api = makeAPI(
            flags: .init(readV2: false, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)

        await api.syncProviderAccountQuotas(
            [account],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let row = try XCTUnwrap(
            (root["p_rows"] as? [[String: Any]])?.first
        )
        XCTAssertNil(row["plan_type"])
        XCTAssertEqual(row["plan_source"] as? String, "userConfirmed")
        XCTAssertEqual(row["plan_confidence"] as? String, "high")
        XCTAssertEqual(
            row["plan_observed_at"] as? String,
            "2026-07-24T02:59:00.125Z"
        )
        XCTAssertEqual(
            row["observed_at"] as? String,
            "2026-07-24T03:00:00.250Z"
        )
    }

    func testV2WriteOmitsCloudTextBeyondServerLimit()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/upsert_provider_account_quotas"
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
        let account = ProviderAccountUsage(
            id: Self.accountUsage.id,
            provider: .claude,
            accountLabel: oversized,
            planEvidence: ProviderPlanEvidence(
                rawValue: oversized,
                displayValue: oversized,
                source: .userConfirmed,
                confidence: .high,
                observedAt: sharedISO8601Parse(
                    "2026-07-24T02:59:00Z"
                )
            ),
            quota: -100,
            remaining: -60,
            tiers: tiers,
            resetTime: "not-a-timestamp",
            observedAt: "2026-07-24T03:00:00Z",
            sourceDeviceID: nil,
            statusText: "40% used"
        )

        let api = makeAPI(
            flags: .init(readV2: false, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        await api.syncProviderAccountQuotas(
            [account],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
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

    func testV2WriteSkipsInvalidObservationWithoutDroppingValidSibling()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/upsert_provider_account_quotas"
            )
            return .json(#"{"accounts_synced":1}"#)
        }
        let invalid = ProviderAccountUsage(
            id: UUID(
                uuidString:
                    "55555555-5555-4555-8555-555555555555"
            )!,
            provider: .claude,
            accountLabel: "Invalid",
            planEvidence: ProviderPlanEvidence(
                rawValue: nil,
                displayValue: nil,
                source: .unknown,
                confidence: .unavailable,
                observedAt: nil
            ),
            quota: 100,
            remaining: 50,
            tiers: [],
            resetTime: nil,
            observedAt: "not-a-timestamp",
            sourceDeviceID: nil,
            statusText: ""
        )

        let api = makeAPI(
            flags: .init(readV2: false, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        await api.syncProviderAccountQuotas(
            [invalid, Self.accountUsage],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [String: Any]
        )
        let rows = try XCTUnwrap(
            root["p_rows"] as? [[String: Any]]
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows.first?["account_id"] as? String,
            Self.accountUsage.id.uuidString.lowercased()
        )
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self)
                .contains("not-a-timestamp")
        )
    }

    func testLegacyQuotaWriteOmitsEmailShapedPlanType() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/provider_quotas"
            )
            return .json("[]")
        }
        let email = "vertex-user@example.com"
        let usage = ProviderUsage(
            provider: ProviderKind.vertexAI.rawValue,
            today_usage: 40,
            week_usage: 40,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: 100,
            remaining: 60,
            plan_type: email,
            status_text: "40% used",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
        let api = makeAPI(
            flags: .init(readV2: false, writeV2: false)
        )
        _ = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "clipulse-access-token",
            refreshToken: "clipulse-refresh-token",
            userID: "99999999-9999-4999-8999-999999999999",
            transitionGeneration: 1
        )
        let lease = try await requireAuthorizationLease(for: api)

        await api.syncProviderQuotas(
            [CollectorResult(usage: usage, dataKind: .quota)],
            authorizationLease: lease
        )

        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let rows = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body)
                as? [[String: Any]]
        )
        let row = try XCTUnwrap(rows.first)

        XCTAssertTrue(row["plan_type"] is NSNull)
        XCTAssertFalse(
            String(decoding: body, as: UTF8.self).contains(email)
        )
    }

    func testV2ModeDoesNotIssueLegacyProviderQuotaWrite()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTFail(
                "v2 mode must not write the legacy table directly: \(request)"
            )
            return .json("{}", status: 500)
        }
        let usage = ProviderUsage(
            provider: ProviderKind.claude.rawValue,
            today_usage: 20,
            week_usage: 20,
            estimated_cost_today: 0,
            estimated_cost_week: 0,
            cost_status_today: "Unavailable",
            cost_status_week: "Unavailable",
            quota: 100,
            remaining: 80,
            plan_type: "Max",
            status_text: "20% used",
            trend: [],
            recent_sessions: [],
            recent_errors: []
        )
        let api = makeAPI(
            flags: .init(readV2: false, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)

        await api.syncProviderQuotas(
            [CollectorResult(usage: usage, dataKind: .quota)],
            authorizationLease: lease
        )

        XCTAssertTrue(
            ProviderAccountAPIStubProtocol.recordedRequests().isEmpty
        )
    }

    func testStatusWriteUsesDedicatedCredentialFreeRPC() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/set_provider_account_statuses"
            )
            return .json(#"{"accounts_updated":1}"#)
        }

        let api = makeAPI(flags: .init(readV2: false, writeV2: true))
        let lease = try await requireAuthorizationLease(for: api)
        let synced = await api.syncProviderAccountStatuses(
            [
                ProviderAccountStatusUpdate(
                    accountID: Self.accountUsage.id,
                    provider: .claude,
                    isEnabled: false
                ),
            ],
            authorizationLease: lease
        )

        XCTAssertTrue(synced)
        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try XCTUnwrap(object as? [String: Any])
        let rows = try XCTUnwrap(root["p_rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(
            row["account_id"] as? String,
            "33333333-3333-4333-8333-333333333333"
        )
        XCTAssertEqual(row["status"] as? String, "disabled")
        XCTAssertEqual(row["provider"] as? String, "Claude")
        XCTAssertEqual(
            Set(row.keys),
            ["account_id", "provider", "status"]
        )
        XCTAssertTrue(
            Self.recursiveKeys(in: object).allSatisfy {
                !$0.lowercased().contains("token")
                    && !$0.lowercased().contains("cookie")
                    && !$0.lowercased().contains("secret")
            }
        )
    }

    func testDeleteWriteTargetsOneAccountThroughDedicatedRPC()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/delete_provider_account"
            )
            return .json(
                #"{"accounts_deleted":1,"tombstones_persisted":1}"#
            )
        }

        let api = makeAPI(flags: .init(readV2: false, writeV2: true))
        let lease = try await requireAuthorizationLease(for: api)
        let deleted = await api.deleteProviderAccount(
            Self.accountUsage.id,
            provider: .claude,
            authorizationLease: lease
        )

        XCTAssertTrue(deleted)
        let request = try XCTUnwrap(
            ProviderAccountAPIStubProtocol.recordedRequests().first
        )
        let body = try XCTUnwrap(request.httpBody)
        let object = try JSONSerialization.jsonObject(with: body)
        let root = try XCTUnwrap(object as? [String: Any])
        XCTAssertEqual(
            root["p_account_id"] as? String,
            "33333333-3333-4333-8333-333333333333"
        )
        XCTAssertEqual(root["p_provider"] as? String, "Claude")
        XCTAssertEqual(Set(root.keys), ["p_account_id", "p_provider"])
    }

    func testDeleteRequiresServerTombstoneAcknowledgement() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTAssertEqual(
                request.url?.path,
                "/rest/v1/rpc/delete_provider_account"
            )
            return .json(
                #"{"accounts_deleted":1,"tombstones_persisted":0}"#
            )
        }

        let api = makeAPI(flags: .init(readV2: false, writeV2: true))
        let lease = try await requireAuthorizationLease(for: api)

        let deleted = await api.deleteProviderAccount(
            Self.accountUsage.id,
            provider: .claude,
            authorizationLease: lease
        )

        XCTAssertFalse(
            deleted,
            "the local outbox may clear only after the server persisted a tombstone"
        )
    }

    func testWriteFlagOffMakesNoV2Request() async throws {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTFail("write-disabled API must not send \(request)")
            return .json("{}", status: 500)
        }

        let api = makeAPI(flags: .init(readV2: true, writeV2: false))
        let lease = try await requireAuthorizationLease(for: api)
        await api.syncProviderAccountQuotas(
            [Self.accountUsage],
            authorizationLease: lease
        )
        let statusSynced = await api.syncProviderAccountStatuses(
            [
                ProviderAccountStatusUpdate(
                    accountID: Self.accountUsage.id,
                    provider: .claude,
                    isEnabled: false
                ),
            ],
            authorizationLease: lease
        )
        let deleted = await api.deleteProviderAccount(
            Self.accountUsage.id,
            provider: .claude,
            authorizationLease: lease
        )

        XCTAssertFalse(statusSynced)
        XCTAssertFalse(deleted)
        XCTAssertTrue(
            ProviderAccountAPIStubProtocol.recordedRequests().isEmpty
        )
    }

    func testAccountSwitchDuring401RefreshCannotRetryV2WriteAsNewUser()
        async throws
    {
        let refreshStarted = expectation(
            description: "old session refresh started"
        )
        ProviderAccountAPIStubProtocol.handler = { request in
            switch request.url?.path {
            case "/rest/v1/rpc/upsert_provider_account_quotas":
                return .json(
                    #"{"message":"expired"}"#,
                    status: 401
                )
            case "/auth/v1/token":
                refreshStarted.fulfill()
                return .json(
                    """
                    {
                      "access_token": "user-a-rotated",
                      "refresh_token": "user-a-refresh-rotated"
                    }
                    """,
                    delay: 0.25
                )
            default:
                XCTFail(
                    "unexpected request \(request.url?.absoluteString ?? "nil")"
                )
                return .json("{}", status: 500)
            }
        }

        let api = makeAPI(
            token: "user-a-access",
            flags: .init(readV2: false, writeV2: true)
        )
        await api.updateRefreshToken("user-a-refresh")
        let lease = try await requireAuthorizationLease(for: api)

        let sync = Task {
            await api.syncProviderAccountQuotas(
                [Self.accountUsage],
                authorizationLease: lease
            )
        }

        await fulfillment(of: [refreshStarted], timeout: 1)
        await api.updateToken("user-b-access")
        await api.updateRefreshToken("user-b-refresh")
        await sync.value

        let upserts = ProviderAccountAPIStubProtocol.recordedRequests()
            .filter {
                $0.url?.path
                    == "/rest/v1/rpc/upsert_provider_account_quotas"
            }
        XCTAssertEqual(upserts.count, 1)
        XCTAssertEqual(
            upserts.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer user-a-access"
        )
        XCTAssertFalse(
            upserts.contains {
                $0.value(forHTTPHeaderField: "Authorization")
                    == "Bearer user-b-access"
            },
            "an old account snapshot must never retry under the new user"
        )
    }

    func testStaleLeasePreventsDailyUsageAndBudgetWritesFromStarting()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            XCTFail(
                "a stale refresh lease must not send "
                    + (request.url?.absoluteString ?? "nil")
            )
            return .json("{}", status: 500)
        }

        let api = makeAPI(
            token: "user-a-access",
            flags: .init(readV2: true, writeV2: true)
        )
        let lease = try await requireAuthorizationLease(for: api)
        await api.updateToken("user-b-access")

        _ = try? await api.evaluateBudgetAlerts(
            authorizationLease: lease
        )
        let statusSynced = await api.syncProviderAccountStatuses(
            [
                ProviderAccountStatusUpdate(
                    accountID: Self.accountUsage.id,
                    provider: .claude,
                    isEnabled: false
                ),
            ],
            authorizationLease: lease
        )
        let deleted = await api.deleteProviderAccount(
            Self.accountUsage.id,
            provider: .claude,
            authorizationLease: lease
        )
        await api.syncDailyUsage(
            CostUsageScanResult(entries: [
                .init(
                    date: "2026-07-24",
                    provider: "Claude",
                    model: "claude-test",
                    inputTokens: 10,
                    cachedTokens: 0,
                    outputTokens: 5,
                    costUSD: 0.01
                ),
            ]),
            authorizationLease: lease
        )

        XCTAssertFalse(statusSynced)
        XCTAssertFalse(deleted)
        XCTAssertTrue(
            ProviderAccountAPIStubProtocol.recordedRequests().isEmpty
        )
    }
    #endif

    private func makeAPI(
        token: String = "clipulse-access-token",
        flags: ProviderAccountFeatureFlags
    ) -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderAccountAPIStubProtocol.self]
        return APIClient(
            token: token,
            supabaseURL: "https://provider-account.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config),
            providerAccountFlags: flags
        )
    }

    private func requireAuthorizationLease(
        for api: APIClient
    ) async throws -> APIAuthorizationLease {
        let lease = await api.authorizationLease()
        return try XCTUnwrap(lease)
    }

    private static func recursiveKeys(in value: Any) -> [String] {
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

    private static let accountUsage = ProviderAccountUsage(
        id: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        provider: .claude,
        accountLabel: "Work",
        planEvidence: ProviderPlanEvidence(
            rawValue: "max",
            displayValue: "Max",
            source: .userConfirmed,
            confidence: .high,
            observedAt: sharedISO8601Parse("2026-07-24T02:59:00Z")
        ),
        quota: 100,
        remaining: 60,
        tiers: [
            TierDTO(
                name: "5h Window",
                quota: 100,
                remaining: 60,
                reset_time: "2026-07-24T08:00:00Z",
                windowMinutes: 300,
                role: .primary
            ),
        ],
        resetTime: "2026-07-24T08:00:00Z",
        observedAt: "2026-07-24T03:00:00Z",
        sourceDeviceID: UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        ),
        statusText: "40% used"
    )

    private static func usage(
        id: UUID,
        label: String,
        remaining: Int,
        observedAt: String
    ) -> ProviderAccountUsage {
        ProviderAccountUsage(
            id: id,
            provider: .claude,
            accountLabel: label,
            planEvidence: ProviderPlanEvidence(
                rawValue: "max",
                displayValue: "Max",
                source: .userConfirmed,
                confidence: .high,
                observedAt: sharedISO8601Parse(observedAt)
            ),
            quota: 100,
            remaining: remaining,
            tiers: [],
            resetTime: nil,
            observedAt: observedAt,
            sourceDeviceID: nil,
            statusText: "\(100 - remaining)% used"
        )
    }

    private static func usage(
        id: UUID,
        label: String,
        remaining: Int,
        observedAt: String,
        planRawValue: String?,
        planObservedAt: String?
    ) -> ProviderAccountUsage {
        ProviderAccountUsage(
            id: id,
            provider: .claude,
            accountLabel: label,
            planEvidence: ProviderPlanEvidence(
                rawValue: planRawValue,
                displayValue: planRawValue?.capitalized,
                source: planRawValue == nil ? .unknown : .userConfirmed,
                confidence: planRawValue == nil ? .unavailable : .high,
                observedAt: planObservedAt.flatMap(sharedISO8601Parse)
            ),
            quota: 100,
            remaining: remaining,
            tiers: [],
            resetTime: nil,
            observedAt: observedAt,
            sourceDeviceID: nil,
            statusText: "\(100 - remaining)% used"
        )
    }

    private static let legacySummaryJSON = """
    [
      {
        "provider": "Claude",
        "today_usage": 12,
        "total_usage": 34,
        "estimated_cost": 4.5,
        "estimated_cost_today": 0.75,
        "estimated_cost_30_day": 8.5,
        "quota": 100,
        "remaining": 44,
        "plan_type": "Pro",
        "reset_time": "2026-07-24T08:00:00Z",
        "tiers": []
      }
    ]
    """

    private static let v2SummaryJSON = """
    [
      {
        "provider": "Claude",
        "today_usage": 123,
        "total_usage": 456,
        "estimated_cost": 7.5,
        "estimated_cost_today": 1.25,
        "estimated_cost_30_day": 9.75,
        "accounts": [
          {
            "id": "11111111-1111-4111-8111-111111111111",
            "provider": "Claude",
            "account_label": "Work",
            "plan_evidence": {
              "raw_value": "max",
              "display_value": "Max",
              "source": "providerAPI",
              "confidence": "high",
              "observed_at": "2026-07-24T00:59:00Z"
            },
            "quota": 100,
            "remaining": 80,
            "tiers": [
              {
                "name": "5h Window",
                "quota": 100,
                "remaining": 80,
                "reset_time": "2026-07-24T08:00:00Z",
                "windowMinutes": 300,
                "role": "primary"
              }
            ],
            "reset_time": "2026-07-24T08:00:00Z",
            "observed_at": "2026-07-24T01:01:00Z",
            "source_device_id": null,
            "status_text": "20% used",
            "status": "active",
            "updated_at": "2026-07-24T03:59:00Z"
          },
          {
            "id": "22222222-2222-4222-8222-222222222222",
            "provider": "Claude",
            "account_label": "Personal",
            "plan_evidence": {
              "raw_value": "pro",
              "display_value": "Pro",
              "source": "userConfirmed",
              "confidence": "high",
              "observed_at": "2026-07-24T01:00:00Z"
            },
            "quota": 100,
            "remaining": 20,
            "tiers": [],
            "reset_time": "2026-07-24T09:00:00Z",
            "observed_at": "2026-07-24T01:02:00Z",
            "source_device_id": null,
            "status_text": "80% used",
            "status": "active",
            "updated_at": "2026-07-24T04:00:00Z"
          }
        ]
      }
    ]
    """
}

#if os(macOS)
@MainActor
final class DataRefreshManagerProviderAccountBoundaryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ProviderAccountAPIStubProtocol.reset()
        UserDefaults.standard.removeObject(
            forKey: "cli_pulse_previous_alert_ids_v1"
        )
        UserDefaults.standard.removeObject(
            forKey: "cli_pulse_previous_alert_suppression_keys_v1"
        )
    }

    override func tearDown() {
        ProviderAccountAPIStubProtocol.reset()
        UserDefaults.standard.removeObject(
            forKey: "cli_pulse_previous_alert_ids_v1"
        )
        UserDefaults.standard.removeObject(
            forKey: "cli_pulse_previous_alert_suppression_keys_v1"
        )
        super.tearDown()
    }

    func testAccountSwitchDropsOldRefreshPayloadAndNotifications()
        async throws
    {
        installCloudRefreshHandler(includeAlert: true)
        let api = await makeAPI()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime()
        )
        let commitPause = ProviderAccountAsyncGate()
        let reachedCommitBoundary = expectation(
            description: "refresh reached final async callback"
        )
        var payloads: [DataRefreshManager.RefreshPayload] = []
        var notifications: [AlertRecord] = []
        var afterRefreshCount = 0
        var outcomePublicationCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(notificationsEnabled: true),
                callbacks: makeCallbacks(
                    applyPayload: { payloads.append($0) },
                    sendNotification: { notifications.append($0) },
                    afterRefresh: { afterRefreshCount += 1 },
                    activeSuppressedAlertIDs: {
                        reachedCommitBoundary.fulfill()
                        await commitPause.wait()
                        return []
                    },
                    setCollectorOutcomes: { _ in
                        outcomePublicationCount += 1
                    }
                )
            )
        }

        await fulfillment(of: [reachedCommitBoundary], timeout: 3)
        await api.updateToken("user-b-access")
        await commitPause.open()
        await refresh.value

        XCTAssertTrue(
            payloads.isEmpty,
            "a user-A refresh must never commit provider accounts into user B"
        )
        XCTAssertTrue(
            notifications.isEmpty,
            "a user-A alert must never notify after switching to user B"
        )
        XCTAssertEqual(afterRefreshCount, 0)
        XCTAssertEqual(
            outcomePublicationCount,
            0,
            "a stale cloud refresh must not publish collector outcomes"
        )
    }

    func testAccountSwitchDuringHealthCannotAcquireNewUsersLease()
        async throws
    {
        let healthStarted = expectation(
            description: "user A refresh reached health request"
        )
        installCloudRefreshHandler(
            includeAlert: true,
            healthDelay: 0.25,
            onHealthRequest: {
                healthStarted.fulfill()
            }
        )
        let api = await makeAPI()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime()
        )
        var payloads: [DataRefreshManager.RefreshPayload] = []
        var notifications: [AlertRecord] = []
        var afterRefreshCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(notificationsEnabled: true),
                callbacks: makeCallbacks(
                    applyPayload: { payloads.append($0) },
                    sendNotification: { notifications.append($0) },
                    afterRefresh: { afterRefreshCount += 1 }
                )
            )
        }

        await fulfillment(of: [healthStarted], timeout: 3)
        _ = await api.beginExternalAuthorizationTransition(
            generation: 2
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "user-b-access",
            refreshToken: "user-b-refresh",
            userID: "user-b",
            transitionGeneration: 2
        )
        await refresh.value

        XCTAssertEqual(
            ProviderAccountAPIStubProtocol.requestPaths(),
            ["/auth/v1/health"],
            "a user-A refresh must not continue with user B's authorization"
        )
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertTrue(notifications.isEmpty)
        XCTAssertEqual(afterRefreshCount, 0)
    }

    func testAuthenticatedLocalRefreshCannotUseDifferentUsersLease()
        async throws
    {
        let api = await makeAPI()
        let collectorGate = ProviderAccountCollectorGate()
        let writeOrder = ProviderAccountWriteOrderRecorder()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime(
                collectorGate: collectorGate,
                writeOrderRecorder: writeOrder
            )
        )
        var payloads: [DataRefreshManager.RefreshPayload] = []
        var afterRefreshCount = 0
        var outcomePublicationCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(
                    notificationsEnabled: false,
                    isPaired: false
                ),
                callbacks: makeCallbacks(
                    applyPayload: { payloads.append($0) },
                    afterRefresh: { afterRefreshCount += 1 },
                    setCollectorOutcomes: { _ in
                        outcomePublicationCount += 1
                    }
                )
            )
        }

        await collectorGate.waitUntilEntered()
        _ = await api.beginExternalAuthorizationTransition(
            generation: 2
        )
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "user-b-access",
            refreshToken: nil,
            userID: "user-b",
            transitionGeneration: 2
        )
        await collectorGate.open()
        await refresh.value

        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(afterRefreshCount, 0)
        XCTAssertEqual(
            outcomePublicationCount,
            0,
            "a stale authenticated-local refresh must not publish outcomes"
        )
        let completedWrites = await writeOrder.values
        XCTAssertTrue(
            completedWrites.isEmpty,
            "a stale local refresh must not upload quotas for either user"
        )
        XCTAssertTrue(
            ProviderAccountAPIStubProtocol.recordedRequests()
                .isEmpty
        )
    }

    func testCancelledLocalRefreshDoesNotPublishCollectorOutcomes()
        async
    {
        let api = await makeAPI()
        let collectorGate = ProviderAccountCollectorGate()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime(collectorGate: collectorGate)
        )
        var outcomePublicationCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(
                    notificationsEnabled: false,
                    isPaired: false
                ),
                callbacks: makeCallbacks(
                    applyPayload: { _ in },
                    afterRefresh: {},
                    setCollectorOutcomes: { _ in
                        outcomePublicationCount += 1
                    }
                )
            )
        }

        await collectorGate.waitUntilEntered()
        refresh.cancel()
        await collectorGate.open()
        await refresh.value

        XCTAssertEqual(
            outcomePublicationCount,
            0,
            "a superseded refresh must not publish cancellation-shaped failures"
        )
    }

    func testProviderWritesDoNotDelayPayloadOrLoadingCompletion()
        async throws
    {
        installCloudRefreshHandler(includeAlert: false)
        let api = await makeAPI()
        let syncGate = ProviderAccountAsyncGate()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime(syncGate: syncGate)
        )
        let payloadVisible = expectation(
            description: "payload visible before optional writes finish"
        )
        let loadingFinished = expectation(
            description: "loading ends before optional writes finish"
        )
        var afterRefreshCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(notificationsEnabled: false),
                callbacks: makeCallbacks(
                    setLoading: { isLoading in
                        if !isLoading { loadingFinished.fulfill() }
                    },
                    applyPayload: { _ in payloadVisible.fulfill() },
                    afterRefresh: { afterRefreshCount += 1 }
                )
            )
        }

        await fulfillment(
            of: [payloadVisible, loadingFinished],
            timeout: 3
        )
        await syncGate.open()
        await refresh.value

        XCTAssertEqual(afterRefreshCount, 1)
    }

    func testAuthenticatedLocalProviderWritesDoNotDelayPayload()
        async throws
    {
        let api = await makeAPI()
        let syncGate = ProviderAccountAsyncGate()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime(syncGate: syncGate)
        )
        let payloadVisible = expectation(
            description: "local payload visible before optional writes finish"
        )
        let loadingFinished = expectation(
            description: "local loading ends before optional writes finish"
        )

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(
                    notificationsEnabled: false,
                    isPaired: false
                ),
                callbacks: makeCallbacks(
                    setLoading: { isLoading in
                        if !isLoading { loadingFinished.fulfill() }
                    },
                    applyPayload: { _ in payloadVisible.fulfill() },
                    afterRefresh: {}
                )
            )
        }

        await fulfillment(
            of: [payloadVisible, loadingFinished],
            timeout: 3
        )
        await syncGate.open()
        await refresh.value
    }

    func testV2ProjectionCommitsAfterLegacyCompatibilityWrite()
        async throws
    {
        installCloudRefreshHandler(includeAlert: false)
        let api = await makeAPI()
        let writeOrder = ProviderAccountWriteOrderRecorder()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime(
                writeOrderRecorder: writeOrder
            )
        )

        await manager.refreshAll(
            context: makeContext(notificationsEnabled: false),
            callbacks: makeCallbacks(
                applyPayload: { _ in },
                afterRefresh: {}
            )
        )

        let completedWrites = await writeOrder.values
        XCTAssertEqual(
            completedWrites,
            ["legacy", "account"],
            "v2 must be the last compatibility projection writer"
        )
    }

    func testStaleTokenExpiredResponseCannotSignOutNewSession()
        async throws
    {
        let dashboardRequestStarted = expectation(
            description: "old dashboard request started"
        )
        ProviderAccountAPIStubProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/health":
                return .json("{}")
            case "/rest/v1/rpc/dashboard_summary":
                dashboardRequestStarted.fulfill()
                return .json(
                    #"{"message":"expired"}"#,
                    status: 401,
                    delay: 0.25
                )
            case "/rest/v1/rpc/provider_account_summary":
                return .json("[]")
            case "/rest/v1/sessions", "/rest/v1/devices",
                 "/rest/v1/alerts":
                return .json("[]")
            default:
                XCTFail(
                    "unexpected refresh request "
                        + (request.url?.absoluteString ?? "nil")
                )
                return .json("{}", status: 500)
            }
        }

        let api = await makeAPI()
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime()
        )
        var tokenExpiredCount = 0

        let refresh = Task { @MainActor in
            await manager.refreshAll(
                context: makeContext(notificationsEnabled: false),
                callbacks: makeCallbacks(
                    applyPayload: { _ in },
                    afterRefresh: {},
                    handleTokenExpired: { _ in tokenExpiredCount += 1 }
                )
            )
        }

        await fulfillment(of: [dashboardRequestStarted], timeout: 3)
        await api.updateToken("user-b-access")
        await refresh.value

        XCTAssertEqual(
            tokenExpiredCount,
            0,
            "an old refresh failure must not sign out the new session"
        )
    }

    func testCurrentSessionRefreshTokenRejectionSignsOutExactlyOnce()
        async throws
    {
        ProviderAccountAPIStubProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/health":
                return .json("{}")
            case "/rest/v1/rpc/dashboard_summary":
                return .json(
                    #"{"message":"expired"}"#,
                    status: 401
                )
            case "/auth/v1/token":
                return .json(
                    #"{"message":"refresh token rejected"}"#,
                    status: 401
                )
            case "/rest/v1/rpc/provider_account_summary":
                return .json("[]")
            case "/rest/v1/sessions", "/rest/v1/devices",
                 "/rest/v1/alerts":
                return .json("[]")
            default:
                XCTFail(
                    "unexpected refresh request "
                        + (request.url?.absoluteString ?? "nil")
                )
                return .json("{}", status: 500)
            }
        }

        let api = await makeAPI()
        await api.updateRefreshToken("user-a-refresh")
        let manager = DataRefreshManager(
            api: api,
            localRuntime: .testRuntime()
        )
        var tokenExpiredCount = 0

        await manager.refreshAll(
            context: makeContext(notificationsEnabled: false),
            callbacks: makeCallbacks(
                applyPayload: { _ in },
                afterRefresh: {},
                handleTokenExpired: { _ in tokenExpiredCount += 1 }
            )
        )

        XCTAssertEqual(
            tokenExpiredCount,
            1,
            "the current session must leave the half-authenticated state"
        )
    }

    private func makeAPI() async -> APIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderAccountAPIStubProtocol.self]
        let api = APIClient(
            supabaseURL: "https://provider-account.test",
            supabaseAnonKey: "anon",
            session: URLSession(configuration: config),
            providerAccountFlags: .init(readV2: true, writeV2: true)
        )
        let began = await api.beginExternalAuthorizationTransition(
            generation: 1
        )
        let installed = await api.installExternalAuthenticatedSession(
            accessToken: "user-a-access",
            refreshToken: nil,
            userID: "user-a",
            transitionGeneration: 1
        )
        XCTAssertTrue(began)
        XCTAssertTrue(installed)
        return api
    }

    private func makeContext(
        notificationsEnabled: Bool,
        isPaired: Bool = true
    ) -> DataRefreshManager.Context {
        DataRefreshManager.Context(
            isAuthenticated: true,
            isDemoMode: false,
            isPaired: isPaired,
            isLoading: false,
            notificationsEnabled: notificationsEnabled,
            sessionQuotaNotificationsEnabled: true,
            authenticatedUserID: "user-a",
            // These synchronization tests exercise an explicitly authorized
            // Claude collector. An empty provider set now correctly skips all
            // collectors, which would make the gate-based cases wait forever
            // instead of testing their account-switch boundary.
            providerConfigs: [ProviderConfig(kind: .claude)],
            providerCollectionAuthorized: true,
            providers: [],
            maxProviders: 100,
            currentTierName: "Pro",
            tierResolutionState: .resolvedConfirmed,
            isLocalMode: false,
            // These cases are about provider-account sync, not about consent.
            // Stated explicitly rather than defaulted so the refresh gate can
            // never be the silent reason one of them goes green.
            localScanConsent: .granted
        )
    }

    private func makeCallbacks(
        setLoading: @escaping (Bool) -> Void = { _ in },
        applyPayload: @escaping (DataRefreshManager.RefreshPayload) -> Void,
        sendNotification: @escaping (AlertRecord) -> Void = { _ in },
        afterRefresh: @escaping () -> Void,
        handleTokenExpired: @escaping (String) -> Void = { _ in },
        activeSuppressedAlertIDs: @escaping () async -> Set<String> = { [] },
        setCollectorOutcomes:
            @escaping ([ProviderKind: CollectorOutcome]) -> Void =
                { _ in }
    ) -> DataRefreshManager.Callbacks {
        DataRefreshManager.Callbacks(
            isAuthenticated: { true },
            setLoading: setLoading,
            setLastError: { _ in },
            setServerOnline: { _ in },
            applyPayload: applyPayload,
            sendNotification: sendNotification,
            afterRefresh: afterRefresh,
            handleTokenExpired: handleTokenExpired,
            activeSuppressedAlertIDs: activeSuppressedAlertIDs,
            setNeedsFolderAccess: { _ in },
            setCollectorOutcomes: setCollectorOutcomes
        )
    }

    private func installCloudRefreshHandler(
        includeAlert: Bool,
        healthDelay: TimeInterval = 0,
        onHealthRequest: (() -> Void)? = nil
    ) {
        ProviderAccountAPIStubProtocol.handler = { request in
            switch request.url?.path {
            case "/auth/v1/health":
                onHealthRequest?()
                return .json("{}", delay: healthDelay)
            case "/rest/v1/rpc/dashboard_summary":
                return .json("{}")
            case "/rest/v1/rpc/provider_account_summary":
                return .json(
                    """
                    [{
                      "provider": "Claude",
                      "accounts": [{
                        "id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
                        "provider": "Claude",
                        "account_label": "User A private account",
                        "plan_evidence": {
                          "raw_value": "max",
                          "display_value": "Max",
                          "source": "userConfirmed",
                          "confidence": "high",
                          "observed_at": "2026-07-24T05:00:00Z"
                        },
                        "quota": 100,
                        "remaining": 10,
                        "tiers": [],
                        "observed_at": "2026-07-24T05:01:00Z",
                        "status": "active"
                      }]
                    }]
                    """
                )
            case "/rest/v1/sessions", "/rest/v1/devices":
                return .json("[]")
            case "/rest/v1/alerts":
                if includeAlert {
                    return .json(
                        """
                        [{
                          "id": "user-a-private-alert",
                          "type": "quota",
                          "severity": "Warning",
                          "title": "User A quota",
                          "message": "User A private quota warning",
                          "created_at": "2026-07-24T05:02:00Z",
                          "is_read": false,
                          "is_resolved": false
                        }]
                        """
                    )
                }
                return .json("[]")
            case "/rest/v1/rpc/evaluate_budget_alerts":
                return .json(#"{"alerts_created":0}"#)
            default:
                XCTFail(
                    "unexpected refresh request "
                        + (request.url?.absoluteString ?? "nil")
                )
                return .json("{}", status: 500)
            }
        }
    }
}

private actor ProviderAccountAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor ProviderAccountCollectorGate {
    private var entered = false
    private var isOpen = false
    private var entryWaiters:
        [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters:
        [CheckedContinuation<Void, Never>] = []

    func wait() async {
        entered = true
        let pendingEntryWaiters = entryWaiters
        entryWaiters.removeAll()
        for continuation in pendingEntryWaiters {
            continuation.resume()
        }
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pendingReleaseWaiters = releaseWaiters
        releaseWaiters.removeAll()
        for continuation in pendingReleaseWaiters {
            continuation.resume()
        }
    }
}

private actor ProviderAccountWriteOrderRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

private extension DataRefreshManager.LocalRefreshRuntime {
    static func testRuntime(
        syncGate: ProviderAccountAsyncGate? = nil,
        collectorGate: ProviderAccountCollectorGate? = nil,
        writeOrderRecorder:
            ProviderAccountWriteOrderRecorder? = nil
    ) -> Self {
        Self(
            prepareCredentials: { _ in },
            collectAccountPass: { _ in
                if let collectorGate {
                    await collectorGate.wait()
                }
                return .empty
            },
            readHelperSnapshot: { _ in .empty },
            scanLocal: { _ in
                LocalScanResult(
                    sessions: [],
                    providers: [],
                    totalUsage: 0,
                    totalCost: 0,
                    activeSessionCount: 0
                )
            },
            scanCostUsage: { _ in CostUsageScanResult(entries: []) },
            needsFolderAccessNudge: { _, _ in false },
            syncLegacyQuotas: { _, _ in
                if let syncGate { await syncGate.wait() }
                if let writeOrderRecorder {
                    try? await Task.sleep(
                        nanoseconds: 50_000_000
                    )
                    await writeOrderRecorder.append("legacy")
                }
            },
            syncDailyUsage: { _, _ in
                if let syncGate { await syncGate.wait() }
            },
            syncAccountQuotas: { _, _ in
                if let syncGate { await syncGate.wait() }
                if let writeOrderRecorder {
                    await writeOrderRecorder.append("account")
                }
            }
        )
    }
}
#endif

private final class ProviderAccountAPIStubProtocol: URLProtocol {
    struct StubResponse {
        let status: Int
        let headers: [String: String]
        let body: Data
        let delay: TimeInterval
        let onDeliver: (@Sendable () -> Void)?

        static func json(
            _ text: String,
            status: Int = 200,
            delay: TimeInterval = 0,
            onDeliver: (@Sendable () -> Void)? = nil
        ) -> StubResponse {
            StubResponse(
                status: status,
                headers: ["Content-Type": "application/json"],
                body: Data(text.utf8),
                delay: delay,
                onDeliver: onDeliver
            )
        }
    }

    nonisolated(unsafe) static var handler:
        ((URLRequest) throws -> StubResponse)?
    nonisolated(unsafe) private static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock()
        handler = nil
        requests = []
        lock.unlock()
    }

    static func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func requestPaths() -> [String] {
        recordedRequests().compactMap(\.url?.path)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recordedRequest = Self.requestWithMaterializedBody(request)
        Self.lock.lock()
        Self.requests.append(recordedRequest)
        let handler = Self.handler
        Self.lock.unlock()

        do {
            let stub = try XCTUnwrap(handler)(recordedRequest)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.status,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            let deliver = { [weak self] in
                guard let self, let client = self.client else { return }
                stub.onDeliver?()
                client.urlProtocol(
                    self,
                    didReceive: response,
                    cacheStoragePolicy: .notAllowed
                )
                client.urlProtocol(self, didLoad: stub.body)
                client.urlProtocolDidFinishLoading(self)
            }
            if stub.delay > 0 {
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + stub.delay,
                    execute: deliver
                )
            } else {
                deliver()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func requestWithMaterializedBody(
        _ request: URLRequest
    ) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }

        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}

private final class ProviderAccountStatusDeliveryRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}
