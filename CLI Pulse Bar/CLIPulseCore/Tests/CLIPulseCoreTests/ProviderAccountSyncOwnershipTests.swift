import XCTest
@testable import CLIPulseCore

final class ProviderAccountSyncOwnershipTests: XCTestCase {
    func testUnownedConfigsBindOnceWithoutReassigningAnotherOwner() {
        let unownedID = UUID()
        let existingOwnerID = UUID()
        var configs = [
            ProviderConfig(
                kind: .claude,
                accountID: unownedID
            ),
            ProviderConfig(
                kind: .codex,
                accountID: existingOwnerID,
                syncOwnerUserID: "user-b"
            ),
        ]

        XCTAssertTrue(
            ProviderAccountSyncOwnership.bindUnowned(
                configs: &configs,
                to: " USER-A "
            )
        )
        XCTAssertEqual(
            configs.first {
                $0.accountID == unownedID
            }?.syncOwnerUserID,
            "user-a"
        )
        XCTAssertEqual(
            configs.first {
                $0.accountID == existingOwnerID
            }?.syncOwnerUserID,
            "user-b"
        )

        XCTAssertFalse(
            ProviderAccountSyncOwnership.bindUnowned(
                configs: &configs,
                to: "user-c"
            )
        )
        XCTAssertEqual(
            configs.first {
                $0.accountID == unownedID
            }?.syncOwnerUserID,
            "user-a",
            "a later CLIPulse login must not steal existing configs"
        )
    }

    func testSyncableAccountIDsExcludeUnownedAndDifferentOwner() {
        let ownedByA = UUID()
        let ownedByB = UUID()
        let unowned = UUID()
        let configs = [
            ProviderConfig(
                kind: .claude,
                accountID: ownedByA,
                syncOwnerUserID: "user-a"
            ),
            ProviderConfig(
                kind: .claude,
                accountID: ownedByB,
                syncOwnerUserID: "user-b"
            ),
            ProviderConfig(
                kind: .gemini,
                accountID: unowned
            ),
        ]

        XCTAssertEqual(
            ProviderAccountSyncOwnership.accountIDs(
                in: configs,
                ownedBy: " USER-A "
            ),
            Set([ownedByA])
        )
        XCTAssertEqual(
            ProviderAccountSyncOwnership.ownerForDeletion(
                configs[1]
            ),
            "user-b"
        )
        XCTAssertNil(
            ProviderAccountSyncOwnership.ownerForDeletion(
                configs[2]
            )
        )
    }

    #if os(macOS)
    func testLegacyCloudProjectionUsesOnlyCurrentOwnersAccounts() {
        let accountA = UUID()
        let accountB = UUID()
        let configA = ProviderConfig(
            kind: .claude,
            accountID: accountA,
            sortOrder: 0,
            syncOwnerUserID: "user-a"
        )
        let configB = ProviderConfig(
            kind: .claude,
            accountID: accountB,
            sortOrder: 1,
            syncOwnerUserID: "user-b"
        )
        let results = [
            scopedResult(config: configA, remaining: 90),
            scopedResult(config: configB, remaining: 25),
        ]

        let owned = DataRefreshManager.cloudOwnedAccountResults(
            from: results,
            providerConfigs: [configA, configB],
            authenticatedUserID: " USER-B "
        )
        let legacyProjection =
            DataRefreshManager.providerCompatibilityResults(
                from: owned
            )

        XCTAssertEqual(owned.map(\.accountID), [accountB])
        XCTAssertEqual(
            legacyProjection.first?.usage.remaining,
            25,
            "legacy dual-write must not upload another CLIPulse user's local quota"
        )
    }

    private func scopedResult(
        config: ProviderConfig,
        remaining: Int
    ) -> AccountScopedCollectorResult {
        AccountScopedCollectorResult(
            accountID: config.accountID,
            config: config,
            result: CollectorResult(
                usage: ProviderUsage(
                    provider: config.kind.rawValue,
                    today_usage: 0,
                    week_usage: 0,
                    estimated_cost_today: 0,
                    estimated_cost_week: 0,
                    cost_status_today: "Unavailable",
                    cost_status_week: "Unavailable",
                    quota: 100,
                    remaining: remaining,
                    tiers: [],
                    status_text: "",
                    trend: [],
                    recent_sessions: [],
                    recent_errors: []
                ),
                dataKind: .quota
            )
        )
    }
    #endif
}
