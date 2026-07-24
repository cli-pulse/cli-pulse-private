#if os(macOS)
import XCTest
@testable import CLIPulseCore

final class AccountScopedCollectorTests: XCTestCase {
    private var originalOwnerDefaults: UserDefaults!
    private var ownerDefaults: UserDefaults!
    private var ownerSuiteName: String!

    override func setUp() {
        super.setUp()
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        ownerSuiteName =
            "AccountScopedCollectorTests-\(UUID().uuidString)"
        ownerDefaults = UserDefaults(suiteName: ownerSuiteName)
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        ProviderSharedCredentialOwner.defaults = ownerDefaults
    }

    override func tearDown() {
        ProviderSharedCredentialOwner.defaults = originalOwnerDefaults
        ownerDefaults.removePersistentDomain(forName: ownerSuiteName)
        ownerDefaults = nil
        ownerSuiteName = nil
        originalOwnerDefaults = nil
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
                planOverride: "Max 20x"
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

        let scoped = await DataRefreshManager.runCollectors(
            providerConfigs: configs,
            collectorResolver: { _ in collector }
        )
        let recordedAccountIDs = await recorder.snapshot()

        XCTAssertEqual(Set(recordedAccountIDs), Set([workID, personalID]))
        XCTAssertEqual(scoped.count, 2)
        XCTAssertEqual(Set(scoped.map(\.accountID)), Set([workID, personalID]))

        let accounts = DataRefreshManager.accountUsages(
            from: scoped,
            observedAt: Date(timeIntervalSince1970: 1_774_065_600)
        )
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(Set(accounts.map(\.id)), Set([workID, personalID]))
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
}
#endif
