import Foundation
import XCTest
@testable import CLIPulseCore

final class AgentSetupStateTests: XCTestCase {
    func testNewUserNavigationOrderIsOwnedByStateMachine() {
        var state = AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: false,
                onboardingVersion: nil,
                progress: nil,
                upgradePromptDismissed: false
            ),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        XCTAssertEqual(state.route, .v2Onboarding(.welcome))
        XCTAssertFalse(state.canMoveBackward)

        state.advance()
        XCTAssertEqual(state.route, .v2Onboarding(.privacy))
        XCTAssertTrue(state.canMoveBackward)

        state.advance()
        XCTAssertEqual(state.route, .v2Onboarding(.discovery))
        state.advance()
        XCTAssertEqual(state.route, .v2Onboarding(.review))
        state.advance()
        XCTAssertEqual(state.route, .v2Onboarding(.connection))
        state.advance()
        XCTAssertEqual(state.route, .v2Onboarding(.syncMode))

        state.moveBackward()
        XCTAssertEqual(state.route, .v2Onboarding(.connection))
        state.moveBackward()
        XCTAssertEqual(state.route, .v2Onboarding(.review))
    }

    func testExistingUserUpgradeCannotMoveBeforeDiscovery() {
        var state = AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: true,
                onboardingVersion: nil,
                progress: nil,
                upgradePromptDismissed: false
            ),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        state.acceptExistingUserUpgrade()

        XCTAssertEqual(state.route, .v2Onboarding(.discovery))
        XCTAssertFalse(state.canMoveBackward)
        state.moveBackward()
        XCTAssertEqual(state.route, .v2Onboarding(.discovery))
    }

    func testInterruptedV2SetupRestoresStepAndSelections() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let store = AgentSetupStateStore(defaults: defaults)
        let flags = AgentSetupFeatureFlags(
            newUsersV2: true,
            existingUsersV2: true
        )
        let accountID = UUID(
            uuidString: "44444444-4444-4444-8444-444444444444"
        )!
        var state = AgentSetupState(
            storedState: store.load(),
            featureFlags: flags
        )

        XCTAssertEqual(state.route, .v2Onboarding(.welcome))
        state.beginNewUserSetup()
        state.move(to: .review)
        state.selectAccount(accountID)
        store.save(state)

        let restored = AgentSetupState(
            storedState: store.load(),
            featureFlags: flags
        )
        XCTAssertEqual(restored.route, .v2Onboarding(.review))
        XCTAssertEqual(restored.progress?.selectedAccountIDs, [accountID])
    }

    func testV1CompletedUserIsNeverForcedIntoFullWizard() {
        let flagsOff = AgentSetupFeatureFlags(
            newUsersV2: true,
            existingUsersV2: false
        )
        let flagsOn = AgentSetupFeatureFlags(
            newUsersV2: true,
            existingUsersV2: true
        )
        let v1State = AgentSetupStoredState(
            legacyCompleted: true,
            onboardingVersion: nil,
            progress: nil,
            upgradePromptDismissed: false
        )

        XCTAssertEqual(
            AgentSetupState(
                storedState: v1State,
                featureFlags: flagsOff
            ).route,
            .mainApp
        )

        var offered = AgentSetupState(
            storedState: v1State,
            featureFlags: flagsOn
        )
        XCTAssertEqual(offered.route, .upgradePrompt)

        offered.acceptExistingUserUpgrade()
        XCTAssertEqual(offered.route, .v2Onboarding(.discovery))
    }

    func testRolledBackNewUserProgressCannotBypassUpgradePrompt() {
        var initial = AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: false,
                onboardingVersion: nil,
                progress: nil,
                upgradePromptDismissed: false
            ),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: false
            )
        )
        initial.beginNewUserSetup()
        initial.move(to: .review)

        // Simulate a flag rollback followed by successful completion of the
        // legacy wizard. Re-enabling the existing-user rollout must offer the
        // non-blocking upgrade card instead of restoring the old full-screen
        // new-user step.
        var afterLegacyCompletion = initial.persistenceSnapshot
        afterLegacyCompletion.legacyCompleted = true
        var upgraded = AgentSetupState(
            storedState: afterLegacyCompletion,
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        XCTAssertEqual(upgraded.route, .upgradePrompt)
        upgraded.acceptExistingUserUpgrade()
        XCTAssertEqual(upgraded.route, .v2Onboarding(.discovery))
    }

    func testFutureProgressFailsClosedAndCannotBeOverwritten() {
        let futureAccountID = UUID(
            uuidString: "77777777-7777-4777-8777-777777777777"
        )!
        let futureProgress = AgentSetupProgress(
            version: AgentSetupState.currentVersion + 1,
            step: .connection,
            selectedAccountIDs: [futureAccountID],
            completedAt: nil
        )
        var state = AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: false,
                onboardingVersion: nil,
                progress: futureProgress,
                upgradePromptDismissed: false
            ),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        XCTAssertEqual(state.route, .mainApp)
        let originalSnapshot = state.persistenceSnapshot

        state.beginNewUserSetup()
        state.acceptExistingUserUpgrade()
        state.dismissExistingUserUpgrade()
        state.beginRerun()
        state.move(to: .review)
        state.selectAccount(
            UUID(
                uuidString: "88888888-8888-4888-8888-888888888888"
            )!
        )
        state.deselectAccount(futureAccountID)
        state.complete(at: Date(timeIntervalSince1970: 200))

        XCTAssertEqual(state.persistenceSnapshot, originalSnapshot)
    }

    func testFutureStoredProgressBytesRemainUntouchedOnDowngradeSave()
        throws
    {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let rawFutureProgress = Data(
            """
            {
              "version": 3,
              "step": "connection",
              "selectedAccountIDs": [
                "99999999-9999-4999-8999-999999999999"
              ],
              "completedAt": null,
              "futureField": {"must": "survive"}
            }
            """.utf8
        )
        defaults.set(
            rawFutureProgress,
            forKey: AgentSetupStateStore.progressKey
        )
        defaults.set(
            3,
            forKey: AgentSetupStateStore.onboardingVersionKey
        )
        let store = AgentSetupStateStore(defaults: defaults)
        var state = AgentSetupState(
            storedState: store.load(),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        state.beginNewUserSetup()
        store.save(state)

        XCTAssertEqual(
            defaults.data(forKey: AgentSetupStateStore.progressKey),
            rawFutureProgress
        )
        XCTAssertEqual(
            defaults.integer(
                forKey: AgentSetupStateStore.onboardingVersionKey
            ),
            3
        )
    }

    func testUnknownFutureStepStillFailsClosedAndPreservesBytes() {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let rawFutureProgress = Data(
            """
            {
              "version": 3,
              "step": "providerLinkingV3",
              "selectedAccountIDs": [],
              "completedAt": null,
              "futureField": true
            }
            """.utf8
        )
        defaults.set(
            rawFutureProgress,
            forKey: AgentSetupStateStore.progressKey
        )
        let store = AgentSetupStateStore(defaults: defaults)
        var state = AgentSetupState(
            storedState: store.load(),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        XCTAssertEqual(state.route, .mainApp)
        state.beginNewUserSetup()
        store.save(state)

        XCTAssertEqual(
            defaults.data(forKey: AgentSetupStateStore.progressKey),
            rawFutureProgress
        )
    }

    func testDismissedExistingUserUpgradeRemainsNonBlocking() throws {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        defaults.set(
            true,
            forKey: AgentSetupStateStore.legacyCompletedKey
        )
        let store = AgentSetupStateStore(defaults: defaults)
        let flags = AgentSetupFeatureFlags(
            newUsersV2: true,
            existingUsersV2: true
        )
        var state = AgentSetupState(
            storedState: store.load(),
            featureFlags: flags
        )

        state.dismissExistingUserUpgrade()
        store.save(state)

        let restored = AgentSetupState(
            storedState: store.load(),
            featureFlags: flags
        )
        XCTAssertEqual(restored.route, .mainApp)
    }

    func testRerunSelectionIsIdempotentByStableAccountUUID() {
        let accountID = UUID(
            uuidString: "55555555-5555-4555-8555-555555555555"
        )!
        var state = AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: true,
                onboardingVersion: AgentSetupState.currentVersion,
                progress: AgentSetupProgress(
                    version: AgentSetupState.currentVersion,
                    step: .completed,
                    selectedAccountIDs: [accountID],
                    completedAt: Date(timeIntervalSince1970: 100)
                ),
                upgradePromptDismissed: true
            ),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )

        state.beginRerun()
        state.selectAccount(accountID)
        state.selectAccount(accountID)

        XCTAssertEqual(state.route, .v2Onboarding(.discovery))
        XCTAssertEqual(state.progress?.selectedAccountIDs.count, 1)
        XCTAssertEqual(state.progress?.selectedAccountIDs, [accountID])
    }

    func testResetProgressDoesNotTouchProviderAccountsOrLegacyState()
        throws
    {
        let defaults = makeDefaults()
        defer { remove(defaults) }
        let providerConfigSentinel = Data("provider-configs".utf8)
        defaults.set(
            providerConfigSentinel,
            forKey: ProviderAccountMigration.configsKey
        )
        defaults.set(
            true,
            forKey: AgentSetupStateStore.legacyCompletedKey
        )
        let store = AgentSetupStateStore(defaults: defaults)
        var state = AgentSetupState(
            storedState: store.load(),
            featureFlags: .init(
                newUsersV2: true,
                existingUsersV2: true
            )
        )
        state.acceptExistingUserUpgrade()
        state.selectAccount(
            UUID(
                uuidString: "66666666-6666-4666-8666-666666666666"
            )!
        )
        store.save(state)

        store.resetProgress()

        XCTAssertEqual(
            defaults.data(forKey: ProviderAccountMigration.configsKey),
            providerConfigSentinel
        )
        XCTAssertTrue(
            defaults.bool(
                forKey: AgentSetupStateStore.legacyCompletedKey
            )
        )
        XCTAssertNil(store.load().progress)
        XCTAssertNil(store.load().onboardingVersion)
        XCTAssertFalse(store.load().upgradePromptDismissed)
    }

    func testFeatureFlagsLoadFromIndependentKeys() {
        let defaults = makeDefaults()
        defer { remove(defaults) }

        defaults.set(
            true,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )
        defaults.set(
            false,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )
        XCTAssertEqual(
            AgentSetupFeatureFlags.load(from: defaults),
            .init(newUsersV2: true, existingUsersV2: false)
        )

        defaults.set(
            false,
            forKey: AgentSetupFeatureFlags.newUsersDefaultsKey
        )
        defaults.set(
            true,
            forKey: AgentSetupFeatureFlags.existingUsersDefaultsKey
        )
        XCTAssertEqual(
            AgentSetupFeatureFlags.load(from: defaults),
            .init(newUsersV2: false, existingUsersV2: true)
        )
    }

    private func makeDefaults() -> UserDefaults {
        let name = "AgentSetupStateTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    private func remove(_ defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys {
            defaults.removeObject(forKey: key)
        }
    }
}
