#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class AccountScopedCollectorTests: XCTestCase {
    private var originalOwnerDefaults: UserDefaults!
    private var ownerDefaults: UserDefaults!
    private var ownerSuiteName: String!
    private var originalOwnerMutationLock:
        GeminiCredentialMutationLock!
    private var ownerMutationLockPath: String!
    private var originalOwnerSynchronizeDefaults:
        ((UserDefaults) -> Bool)!

    override func setUp() {
        super.setUp()
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        ownerSuiteName =
            "AccountScopedCollectorTests-\(UUID().uuidString)"
        ownerDefaults = UserDefaults(suiteName: ownerSuiteName)
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        ProviderSharedCredentialOwner.defaults = ownerDefaults
        originalOwnerSynchronizeDefaults =
            ProviderSharedCredentialOwner
                .synchronizeDefaults
        ProviderSharedCredentialOwner
            .synchronizeDefaults = { _ in true }
        ownerMutationLockPath =
            FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "\(ownerSuiteName!).lock"
                )
                .path
        originalOwnerMutationLock =
            ProviderSharedCredentialOwner.mutationLock
        ProviderSharedCredentialOwner.mutationLock =
            GeminiCredentialMutationLock(
                lockFilePath: ownerMutationLockPath
            )
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.mutationLock =
            originalOwnerMutationLock
        ProviderSharedCredentialOwner
            .synchronizeDefaults =
                originalOwnerSynchronizeDefaults
        ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        if FileManager.default.fileExists(
            atPath: ownerMutationLockPath
        ) {
            try? FileManager.default.removeItem(
                atPath: ownerMutationLockPath
            )
        }
        ownerDefaults = nil
        ownerSuiteName = nil
        originalOwnerDefaults = nil
        originalOwnerMutationLock = nil
        ownerMutationLockPath = nil
        originalOwnerSynchronizeDefaults = nil
        super.tearDown()
    }

    private actor Recorder {
        private var accountIDs: [UUID] = []

        func record(_ accountID: UUID) {
            accountIDs.append(accountID)
        }

        func snapshot() -> [UUID] {
            accountIDs
        }
    }

    private final class LockedDateSequence: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [Date]

        init(_ dates: [Date]) {
            self.dates = dates
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return dates.removeFirst()
        }
    }

    private struct RecordingClaudeCollector: ProviderCollector {
        let recorder: Recorder

        let kind: ProviderKind = .claude

        func isAvailable(config: ProviderConfig) -> Bool {
            true
        }

        func collect(config: ProviderConfig) async throws -> CollectorResult {
            await recorder.record(config.accountID)
            return CollectorResult(
                usage: ProviderUsage(
                    provider: ProviderKind.claude.rawValue,
                    today_usage: config.sortOrder,
                    week_usage: config.sortOrder,
                    estimated_cost_today: 0,
                    estimated_cost_week: 0,
                    cost_status_today: "Unavailable",
                    cost_status_week: "Unavailable",
                    quota: 100,
                    remaining: 100 - config.sortOrder,
                    plan_type: "Max",
                    reset_time: nil,
                    tiers: [],
                    status_text: "\(config.sortOrder)% used",
                    trend: [],
                    recent_sessions: [],
                    recent_errors: []
                ),
                dataKind: .quota
            )
        }
    }

    func testTwoClaudeAccountsBothRunAndRetainAccountIdentity() async throws {
        let workID = try XCTUnwrap(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let personalID = try XCTUnwrap(UUID(uuidString: "22222222-2222-4222-8222-222222222222"))
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: workID,
                sortOrder: 20,
                accountLabel: "Work",
                planOverride: "Max 20x",
                planOverrideUpdatedAt:
                    Date(timeIntervalSince1970: 1_774_065_500)
            ),
            ProviderConfig(
                kind: .claude,
                accountID: personalID,
                sortOrder: 10,
                accountLabel: "Personal"
            ),
        ]
        let recorder = Recorder()
        let collector = RecordingClaudeCollector(recorder: recorder)

        let pass = await DataRefreshManager.runCollectorPass(
            providerConfigs: configs,
            collectorResolver: { _ in collector }
        )
        let scoped = pass.accountResults
        let recordedAccountIDs = await recorder.snapshot()

        XCTAssertEqual(Set(recordedAccountIDs), Set([workID, personalID]))
        XCTAssertEqual(
            pass.runs.count,
            configs.count,
            "the account-aware pass must retain one outcome per configured account"
        )
        XCTAssertEqual(
            pass.runs.map(\.config.accountID),
            [workID, personalID],
            "concurrent completion must be reconstructed in input order"
        )
        XCTAssertEqual(
            pass.providerOutcomes[.claude],
            .producedData
        )
        XCTAssertEqual(scoped.count, 2)
        XCTAssertEqual(scoped.map(\.accountID), [workID, personalID])

        let accounts = DataRefreshManager.accountUsages(
            from: scoped,
            observedAt: Date(timeIntervalSince1970: 1_774_065_600)
        )
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(
            accounts.map(\.id),
            [personalID, workID],
            "account output follows persisted sortOrder, then stable tie-breakers"
        )
        XCTAssertEqual(
            accounts.first { $0.id == workID }?.planEvidence.source.rawValue,
            PlanEvidenceSource.userConfirmed.rawValue
        )
        XCTAssertEqual(
            accounts.first { $0.id == workID }?.planEvidence.confidence.rawValue,
            DetectionConfidence.high.rawValue
        )
        XCTAssertEqual(
            accounts.first { $0.id == personalID }?.planEvidence.source.rawValue,
            PlanEvidenceSource.unknown.rawValue
        )
        XCTAssertEqual(
            accounts.first { $0.id == personalID }?.planEvidence.confidence.rawValue,
            DetectionConfidence.low.rawValue
        )

        let compatibility = DataRefreshManager.providerCompatibilityResults(from: scoped)
        XCTAssertEqual(compatibility.count, 1)
        XCTAssertEqual(compatibility.first?.usage.provider, ProviderKind.claude.rawValue)
        XCTAssertEqual(
            compatibility.first?.usage.remaining,
            90,
            "The lowest sortOrder account is the deterministic provider-level compatibility projection"
        )
    }

    func testClearedManualPlanProducesExplicitClearEvidence() throws {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let clearedAt = Date(timeIntervalSince1970: 1_774_065_600.125)
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            planOverrideUpdatedAt: clearedAt
        )
        let result = CollectorResult(
            usage: ProviderUsage(
                provider: ProviderKind.claude.rawValue,
                today_usage: 0,
                week_usage: 0,
                estimated_cost_today: 0,
                estimated_cost_week: 0,
                cost_status_today: "Unavailable",
                cost_status_week: "Unavailable",
                quota: 100,
                remaining: 80,
                plan_type: nil,
                status_text: "20% used",
                trend: [],
                recent_sessions: [],
                recent_errors: []
            ),
            dataKind: .quota
        )
        let accounts = DataRefreshManager.accountUsages(
            from: [
                AccountScopedCollectorResult(
                    accountID: accountID,
                    config: config,
                    result: result,
                    observedAt: clearedAt.addingTimeInterval(60)
                ),
            ]
        )

        let evidence = try XCTUnwrap(accounts.first?.planEvidence)
        XCTAssertNil(evidence.rawValue)
        XCTAssertNil(evidence.displayValue)
        XCTAssertEqual(evidence.source, .userConfirmed)
        XCTAssertEqual(evidence.confidence, .high)
        XCTAssertEqual(evidence.observedAt, clearedAt)
    }

    func testStaleManualPlanSnapshotKeepsItsEditRevision() throws {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let overrideEditedAt =
            Date(timeIntervalSince1970: 1_774_065_600.125)
        let collectorFinishedAt =
            overrideEditedAt.addingTimeInterval(120)
        let config = ProviderConfig(
            kind: .claude,
            accountID: accountID,
            planOverride: "Max 20x",
            planOverrideUpdatedAt: overrideEditedAt
        )
        let result = CollectorResult(
            usage: ProviderUsage(
                provider: ProviderKind.claude.rawValue,
                today_usage: 0,
                week_usage: 0,
                estimated_cost_today: 0,
                estimated_cost_week: 0,
                cost_status_today: "Unavailable",
                cost_status_week: "Unavailable",
                quota: 100,
                remaining: 80,
                plan_type: nil,
                status_text: "20% used",
                trend: [],
                recent_sessions: [],
                recent_errors: []
            ),
            dataKind: .quota
        )

        let accounts = DataRefreshManager.accountUsages(
            from: [
                AccountScopedCollectorResult(
                    accountID: accountID,
                    config: config,
                    result: result,
                    observedAt: collectorFinishedAt
                ),
            ]
        )

        let evidence = try XCTUnwrap(accounts.first?.planEvidence)
        XCTAssertEqual(evidence.rawValue, "Max 20x")
        XCTAssertEqual(
            evidence.observedAt,
            overrideEditedAt,
            "a stale collector completion must not make an old manual plan newer than a later clear"
        )
    }

    func testDetectedPlanUsesCollectionStartBeforeConcurrentManualEdit()
        async throws
    {
        let accountID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        let collectionStartedAt =
            Date(timeIntervalSince1970: 1_774_065_600)
        let manualEditedAt =
            collectionStartedAt.addingTimeInterval(60)
        let collectionFinishedAt =
            manualEditedAt.addingTimeInterval(60)
        let clock = LockedDateSequence(
            [collectionStartedAt, collectionFinishedAt]
        )
        let recorder = Recorder()

        let run = await DataRefreshManager
            .runOneCollectorWithOutcome(
                config: ProviderConfig(
                    kind: .claude,
                    accountID: accountID
                ),
                collector: RecordingClaudeCollector(
                    recorder: recorder
                ),
                now: { clock.next() }
            )

        let scoped = try XCTUnwrap(run.scopedResult)
        XCTAssertEqual(scoped.observedAt, collectionFinishedAt)
        let account = try XCTUnwrap(
            DataRefreshManager.accountUsages(from: [scoped]).first
        )
        XCTAssertEqual(
            account.planEvidence.observedAt,
            collectionStartedAt,
            "a slow detected plan must stay older than a manual edit made while collection was in flight"
        )
        XCTAssertLessThan(
            try XCTUnwrap(account.planEvidence.observedAt),
            manualEditedAt
        )
    }
}
#endif
