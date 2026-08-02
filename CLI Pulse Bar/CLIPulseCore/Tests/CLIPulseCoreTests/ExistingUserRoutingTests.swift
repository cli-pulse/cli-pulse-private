import XCTest
@testable import CLIPulseCore

/// Does an existing 1.44 user land in the app, or get captured by the new-user
/// wizard?
///
/// The v2 onboarding routes on `legacyCompleted`, which used to read one key:
/// `cli_pulse_onboarding_completed`. That flag is written when someone finishes
/// the legacy wizard by pressing the close button — but a user who finished it
/// BY SIGNING IN never had it written. Keying on it alone therefore classifies
/// a large share of the 1.44 installed base as brand new, and the wizard hides
/// the dashboard they already had.
///
/// A flag that a previous release never wrote can never be true for that
/// release's users. That is the shape of the bug, and it is the second time
/// this repository has hit it — `AuthManager.resolveColdLaunchLanding` carries
/// a note saying not to key on this exact flag, for this exact reason.
///
/// These tests are written against the STORE rather than the view, because the
/// store is where the predicate lives and where a future edit would undo it.
final class ExistingUserRoutingTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        // A private suite: these assertions must not depend on — or disturb —
        // whatever the developer's own install happens to have written.
        suiteName = "ExistingUserRoutingTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    /// The regression this file exists for.
    ///
    /// A 1.44 user who completed onboarding by signing in has provider configs
    /// and NO `cli_pulse_onboarding_completed`. Verified against a real install
    /// before writing this: provider configs present, legacy flag present,
    /// local-mode marker absent — and a signed-in user who never dismissed the
    /// wizard lacks the flag too.
    func testSignedInUserWithProviderConfigsIsNotTreatedAsNew() {
        defaults.set(Data("[{\"kind\":\"claude\"}]".utf8),
                     forKey: ProviderAccountMigration.configsKey)
        // Deliberately NOT setting cli_pulse_onboarding_completed.

        XCTAssertTrue(
            AgentSetupStateStore.hasUsedThisAppBefore(defaults),
            "a user with configured providers has plainly used the app before; "
                + "routing them into new-user onboarding hides their dashboard"
        )
    }

    /// The v1.44 W1 local-mode convert: chose "continue without account", so
    /// the marker is set. They may have no provider configs yet and will never
    /// have the legacy flag.
    func testLocalModeUserIsNotTreatedAsNew() {
        defaults.set(true, forKey: AppState.localModeEnabledKey)

        XCTAssertTrue(
            AgentSetupStateStore.hasUsedThisAppBefore(defaults),
            "the local-mode marker is an explicit prior choice by this user"
        )
    }

    /// The original path still works — someone who dismissed the legacy wizard.
    func testLegacyCompletedFlagStillCounts() {
        defaults.set(true, forKey: AgentSetupStateStore.legacyCompletedKey)

        XCTAssertTrue(AgentSetupStateStore.hasUsedThisAppBefore(defaults))
    }

    /// A genuinely fresh install must still get onboarding — otherwise the fix
    /// would trade one broken audience for the other.
    func testFreshInstallIsStillTreatedAsNew() {
        XCTAssertFalse(
            AgentSetupStateStore.hasUsedThisAppBefore(defaults),
            "an install with no trace of prior use is exactly who onboarding is for"
        )
    }

    /// An empty configs blob is still evidence: the key only exists because a
    /// previous build wrote it.
    func testEmptyProviderConfigsBlobStillCounts() {
        defaults.set(Data("[]".utf8), forKey: ProviderAccountMigration.configsKey)

        XCTAssertTrue(
            AgentSetupStateStore.hasUsedThisAppBefore(defaults),
            "the key's existence is the signal, not its contents — a prior build wrote it"
        )
    }

    /// End to end through the store: the routing decision, not just the helper.
    /// `hasUsedThisAppBefore` alone is a Bool→Bool relabel; pinning it proves
    /// nothing about whether the route actually changes.
    func testStoreRoutesExistingUserAwayFromNewUserOnboarding() {
        defaults.set(Data("[{\"kind\":\"claude\"}]".utf8),
                     forKey: ProviderAccountMigration.configsKey)

        let store = AgentSetupStateStore(defaults: defaults)
        let stored = store.load()

        XCTAssertTrue(
            stored.legacyCompleted,
            "the store must carry the widened predicate into the state machine"
        )

        let state = AgentSetupState(
            storedState: stored,
            featureFlags: .init(newUsersV2: true, existingUsersV2: false)
        )
        if case .v2Onboarding = state.route {
            XCTFail(
                "an existing user was routed into new-user onboarding — this is "
                    + "the exact regression: the wizard replaces their dashboard"
            )
        }
    }

    /// And a fresh install still reaches it, so the guard above cannot pass by
    /// making the route unreachable for everyone.
    func testStoreStillRoutesFreshInstallIntoOnboarding() {
        let store = AgentSetupStateStore(defaults: defaults)
        let state = AgentSetupState(
            storedState: store.load(),
            featureFlags: .init(newUsersV2: true, existingUsersV2: false)
        )
        guard case .v2Onboarding = state.route else {
            return XCTFail("a fresh install must still see new-user onboarding")
        }
    }

    /// codex caught this one: the first version of the widened predicate
    /// counted ANY provider-config blob as prior use. But selecting an agent
    /// mid-wizard persists a seeded blob, so a genuinely new user who picks an
    /// account and quits before finishing looked "existing" on relaunch — and
    /// was routed to the main app instead of resuming the setup they were
    /// halfway through. Fixing one broken audience by breaking another.
    func testWizardSeededConfigsDoNotCountAsPriorUse() {
        defaults.set(Data("[{\"kind\":\"claude\"}]".utf8),
                     forKey: ProviderAccountMigration.configsKey)
        defaults.set(true, forKey: AgentSetupStateStore.wizardSeededConfigsKey)

        XCTAssertFalse(
            AgentSetupStateStore.hasUsedThisAppBefore(defaults),
            "the wizard wrote those configs itself — an interrupted new-user "
                + "setup must resume, not be mistaken for an upgrade"
        )
    }

    /// …and once the wizard finishes it clears the marker, so the same blob
    /// then correctly counts.
    func testConfigsCountAgainOnceTheWizardMarkerIsCleared() {
        defaults.set(Data("[{\"kind\":\"claude\"}]".utf8),
                     forKey: ProviderAccountMigration.configsKey)
        defaults.set(true, forKey: AgentSetupStateStore.wizardSeededConfigsKey)
        defaults.removeObject(forKey: AgentSetupStateStore.wizardSeededConfigsKey)

        XCTAssertTrue(AgentSetupStateStore.hasUsedThisAppBefore(defaults))
    }
}


/// `applySelectedAccounts` writes `isEnabled = selectedIDs.contains(id)` for
/// every account the wizard showed, and nothing in the wizard pre-ticks
/// anything — `selectAccount` is only ever reached from a tap.
///
/// So the upgrade flow has a destructive default: accept the prompt, click
/// through without touching a control, and every discovered provider is
/// switched off. Clicking through an upgrade unchanged has to be a no-op.
final class UpgradePreselectionTests: XCTestCase {

    private func upgradeReadyState() -> AgentSetupState {
        AgentSetupState(
            storedState: AgentSetupStoredState(
                legacyCompleted: true,
                onboardingVersion: nil,
                progress: nil,
                upgradePromptDismissed: false
            ),
            featureFlags: .init(newUsersV2: true, existingUsersV2: true)
        )
    }

    func testAcceptingUpgradePreselectsWhatIsAlreadyEnabled() {
        let claude = UUID(), codex = UUID()
        var state = upgradeReadyState()

        state.acceptExistingUserUpgrade(preselecting: [claude, codex])

        XCTAssertEqual(
            state.progress?.selectedAccountIDs, [claude, codex],
            "clicking through the upgrade unchanged must leave these enabled; "
                + "an empty selection disables every provider the user had"
        )
    }

    /// The new-user path must NOT inherit this — nothing is pre-ticked there.
    func testNewUserSetupPreselectsNothing() {
        var state = upgradeReadyState()
        state.beginNewUserSetup()

        XCTAssertEqual(
            state.progress?.selectedAccountIDs, [],
            "a fresh install has nothing to preserve"
        )
    }

    /// A resumed upgrade keeps what the user already ticked — the seed must not
    /// overwrite a real, in-progress choice.
    func testResumedUpgradeKeepsTheUsersOwnSelection() {
        let chosen = UUID(), enabled = UUID()
        var state = upgradeReadyState()
        state.acceptExistingUserUpgrade(preselecting: [chosen])
        state.deselectAccount(chosen)
        let theirPick = UUID()
        state.selectAccount(theirPick)

        state.acceptExistingUserUpgrade(preselecting: [enabled])

        XCTAssertEqual(
            state.progress?.selectedAccountIDs, [theirPick],
            "re-entering must not discard a selection the user made by hand"
        )
    }
}

/// Two UserDefaults keys are duplicated into `AgentSetupStateStore` rather than
/// imported — one because its owner is main-actor isolated, one because its
/// owner lives in the app target. A duplicated constant drifts silently: rename
/// it on one side and the predicate simply stops matching, with no compile
/// error and no failing assertion anywhere else.
final class DuplicatedKeyLiteralTests: XCTestCase {

    /// `AppState.localModeEnabledKey` is the source of truth.
    func testLocalModeKeyMatchesItsSource() {
        XCTAssertEqual(
            AgentSetupStateStore.localModeEnabledKey,
            AppState.localModeEnabledKey,
            "the copy in AgentSetupStateStore has drifted from AuthManager's "
                + "constant — existing local-mode users will be misrouted"
        )
    }

    /// `OnboardingWizardView.seededConfigsKey` is the source of truth, and it
    /// lives in the app target, so this pins the literal instead. If the wizard
    /// renames it, this fails and points at the other half.
    func testWizardSeededKeyLiteralIsPinned() {
        XCTAssertEqual(
            AgentSetupStateStore.wizardSeededConfigsKey,
            "cli_pulse_agent_setup_seeded_provider_configs_v2",
            "if OnboardingWizardView renamed its seededConfigsKey, update this "
                + "too — otherwise an interrupted new-user setup stops resuming"
        )
    }
}
