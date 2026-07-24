import XCTest
@testable import CLIPulseCore

@MainActor
final class ProviderAccountManagementTests: XCTestCase {
    private var originalOwnerDefaults: UserDefaults!
    private var ownerDefaults: UserDefaults!
    private var ownerSuiteName: String!

    override func setUp() {
        super.setUp()
        originalOwnerDefaults = ProviderSharedCredentialOwner.defaults
        ownerSuiteName =
            "ProviderAccountManagementTests-\(UUID().uuidString)"
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

    func testAddAccountKeepsSameProviderAccountsDistinct() throws {
        let existingID = try XCTUnwrap(
            UUID(uuidString: "11111111-1111-4111-8111-111111111111")
        )
        let addedID = try XCTUnwrap(
            UUID(uuidString: "22222222-2222-4222-8222-222222222222")
        )
        let state = ProviderState()
        state.providerConfigs = [
            ProviderConfig(
                kind: .claude,
                accountID: existingID,
                isEnabled: true,
                sortOrder: 4,
                accountLabel: "Personal"
            ),
        ]

        let created = state.addProviderAccount(
            kind: .claude,
            accountID: addedID
        )

        XCTAssertEqual(created, addedID)
        XCTAssertEqual(
            state.configs(for: .claude).map(\.accountID),
            [existingID, addedID]
        )
        XCTAssertFalse(
            try XCTUnwrap(
                state.providerConfigs.first {
                    $0.accountID == addedID
                }
            ).isEnabled
        )
        XCTAssertEqual(
            state.providerConfigs.first {
                $0.accountID == addedID
            }?.sortOrder,
            5
        )
        XCTAssertTrue(
            state.draftProviderAccountIDs.contains(addedID)
        )
        XCTAssertTrue(state.commitProviderAccountDraft(addedID))
        XCTAssertFalse(
            state.draftProviderAccountIDs.contains(addedID)
        )
    }

    func testCancelDraftDoesNotRemoveExistingAccount() throws {
        let existingID = try XCTUnwrap(
            UUID(uuidString: "99999999-9999-4999-8999-999999999999")
        )
        let draftID = try XCTUnwrap(
            UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")
        )
        let state = ProviderState()
        state.providerConfigs = [
            ProviderConfig(
                kind: .gemini,
                accountID: existingID
            ),
        ]
        _ = state.addProviderAccount(
            kind: .gemini,
            accountID: draftID
        )

        XCTAssertFalse(
            state.cancelProviderAccountDraft(existingID)
        )
        XCTAssertTrue(state.cancelProviderAccountDraft(draftID))
        XCTAssertEqual(
            state.providerConfigs.map(\.accountID),
            [existingID]
        )
    }

    func testEnableAndRemoveMutateOnlyExactAccountID() throws {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "33333333-3333-4333-8333-333333333333")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "44444444-4444-4444-8444-444444444444")
        )
        let state = ProviderState()
        state.providerConfigs = [
            ProviderConfig(
                kind: .codex,
                accountID: firstID,
                isEnabled: true,
                accountLabel: "Work"
            ),
            ProviderConfig(
                kind: .codex,
                accountID: secondID,
                isEnabled: false,
                accountLabel: "Personal"
            ),
        ]

        XCTAssertTrue(
            state.setProviderAccountEnabled(
                secondID,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            try XCTUnwrap(
                state.providerConfigs.first {
                    $0.accountID == firstID
                }
            ).isEnabled
        )
        XCTAssertTrue(
            try XCTUnwrap(
                state.providerConfigs.first {
                    $0.accountID == secondID
                }
            ).isEnabled
        )

        let removed = state.removeProviderAccount(firstID)

        XCTAssertEqual(removed?.accountID, firstID)
        XCTAssertEqual(state.providerConfigs.map(\.accountID), [secondID])
        XCTAssertTrue(
            try XCTUnwrap(state.providerConfigs.first).isEnabled
        )
    }

    func testSecondAccountDoesNotConsumeAnotherProviderPlanSlot() throws {
        let defaults = UserDefaults.standard
        let helperDefaults = UserDefaults(
            suiteName: HelperIPC.suiteName
        )
        let originalConfigs = defaults.data(
            forKey: ProviderAccountMigration.configsKey
        )
        let originalHelperConfigs = helperDefaults?.data(
            forKey: HelperIPC.providerConfigsKey
        )
        defer {
            if let originalConfigs {
                defaults.set(
                    originalConfigs,
                    forKey: ProviderAccountMigration.configsKey
                )
            } else {
                defaults.removeObject(
                    forKey: ProviderAccountMigration.configsKey
                )
            }
            if let originalHelperConfigs {
                helperDefaults?.set(
                    originalHelperConfigs,
                    forKey: HelperIPC.providerConfigsKey
                )
            } else {
                helperDefaults?.removeObject(
                    forKey: HelperIPC.providerConfigsKey
                )
            }
        }

        let state = AppState()
        let limit = state.subscriptionManager.maxProviders
        guard limit > 0,
              ProviderKind.allCases.count > limit
        else {
            throw XCTSkip(
                "Requires a finite provider plan with another provider kind"
            )
        }

        let enabledKinds = Array(
            ProviderKind.allCases.prefix(limit)
        )
        state.providerConfigs = enabledKinds.enumerated().map {
            index,
            kind in
            ProviderConfig(
                kind: kind,
                isEnabled: true,
                sortOrder: index
            )
        }
        let secondAccountID = state.addProviderAccount(
            kind: try XCTUnwrap(enabledKinds.first)
        )

        state.tierLimitWarning = nil
        state.setProviderAccountEnabled(
            secondAccountID,
            isEnabled: true
        )

        XCTAssertTrue(
            try XCTUnwrap(
                state.providerConfigs.first {
                    $0.accountID == secondAccountID
                }
            ).isEnabled,
            "another account for an enabled provider must fit in the same plan slot"
        )
        XCTAssertNil(state.tierLimitWarning)

        let extraKind = ProviderKind.allCases[limit]
        let extraAccountID = state.addProviderAccount(
            kind: extraKind
        )
        state.setProviderAccountEnabled(
            extraAccountID,
            isEnabled: true
        )

        XCTAssertFalse(
            try XCTUnwrap(
                state.providerConfigs.first {
                    $0.accountID == extraAccountID
                }
            ).isEnabled,
            "a genuinely new provider kind remains subject to the plan limit"
        )
        XCTAssertNotNil(state.tierLimitWarning)
    }

    func testMostConstrainedAccountUsesLowestRemainingFraction() throws {
        let comfortableID = try XCTUnwrap(
            UUID(uuidString: "55555555-5555-4555-8555-555555555555")
        )
        let constrainedID = try XCTUnwrap(
            UUID(uuidString: "66666666-6666-4666-8666-666666666666")
        )
        let comfortable = makeUsage(
            id: comfortableID,
            remaining: 80,
            quota: 100
        )
        let constrained = makeUsage(
            id: constrainedID,
            remaining: 10,
            quota: 100
        )

        XCTAssertEqual(
            ProviderState.mostConstrainedAccount(
                in: [comfortable, constrained]
            )?.id,
            constrainedID
        )
        XCTAssertEqual(
            try XCTUnwrap(
                ProviderState.remainingFraction(for: constrained)
            ),
            0.1,
            accuracy: 0.0001
        )
    }

    func testDisabledAccountCannotBecomeMostConstrained() throws {
        let enabledID = try XCTUnwrap(
            UUID(uuidString: "77777777-7777-4777-8777-777777777777")
        )
        let disabledID = try XCTUnwrap(
            UUID(uuidString: "88888888-8888-4888-8888-888888888888")
        )
        let enabled = makeUsage(
            id: enabledID,
            remaining: 80,
            quota: 100
        )
        let staleDisabled = makeUsage(
            id: disabledID,
            remaining: 5,
            quota: 100
        )

        XCTAssertEqual(
            ProviderState.mostConstrainedAccount(
                in: [enabled, staleDisabled],
                enabledAccountIDs: [enabledID]
            )?.id,
            enabledID
        )
    }

    private func makeUsage(
        id: UUID,
        remaining: Int,
        quota: Int
    ) -> ProviderAccountUsage {
        ProviderAccountUsage(
            id: id,
            provider: .claude,
            accountLabel: nil,
            planEvidence: ProviderPlanEvidence(
                rawValue: nil,
                displayValue: nil,
                source: .unknown,
                confidence: .unavailable,
                observedAt: nil
            ),
            quota: quota,
            remaining: remaining,
            tiers: [],
            resetTime: nil,
            observedAt: nil,
            sourceDeviceID: nil,
            statusText: "Operational"
        )
    }
}
