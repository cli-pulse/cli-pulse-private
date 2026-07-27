#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Pin the macOS-only `AppState.continueWithoutAccount()` contract
/// added in iter17. This is the user's "Use local mode" entry point
/// from the signed-out Settings tab.
///
/// Pre-iter17 the SettingsTab button only mutated `state.selectedTab
/// = .overview`, but `refreshAll` early-exited at the `!isAuthenti-
/// cated` gate so the dashboard stayed empty. iter17 makes the button
/// actually flip into local mode (collector results applied,
/// `MenuBarView` routes to `connectedView`, etc.).
///
/// We pin the synchronous state mutations directly. The downstream
/// `Task { await refreshAll() }` spawns asynchronously and depends
/// on a real APIClient + collectors, so its end-to-end behavior is
/// covered by manual real-device verification + `RefreshRouterTests`
/// (which pins the routing decision the spawned task will reach).
@MainActor
final class ContinueWithoutAccountTests: XCTestCase {

    /// Headline contract: after `continueWithoutAccount()`, the user
    /// is in local mode, on the Overview tab, with `serverOnline =
    /// true` so the "Server offline" banner doesn't flash.
    func testContinueWithoutAccountFlipsLocalModeAndOverview() {
        let state = AppState()
        // Mid-session preconditions a signed-out user could be in:
        // not authenticated, on Settings (the iter16 default landing).
        state.isAuthenticated = false
        state.isLocalMode = false
        state.selectedTab = .settings
        state.serverOnline = false

        state.continueWithoutAccount(defaults: Self.isolatedDefaults())

        XCTAssertTrue(state.isLocalMode,
                      "must flip isLocalMode → MenuBarView routes to connectedView")
        XCTAssertEqual(state.selectedTab, .overview,
                       "must land on Overview tab so the user sees the local-mode-ready guide")
        XCTAssertTrue(state.serverOnline,
                      "must clear serverOnline=false so 'Server offline' banner doesn't flash on entry")
    }

    /// Defense: `continueWithoutAccount` is callable from any tab,
    /// not only Settings. Idempotent for callers who somehow ended
    /// up here twice (e.g. tap-tap on the button before the popover
    /// re-renders).
    func testContinueWithoutAccountIsIdempotent() {
        let state = AppState()
        state.continueWithoutAccount(defaults: Self.isolatedDefaults())
        let firstSnapshot = (state.isLocalMode, state.selectedTab, state.serverOnline)

        state.continueWithoutAccount(defaults: Self.isolatedDefaults())
        let secondSnapshot = (state.isLocalMode, state.selectedTab, state.serverOnline)

        XCTAssertEqual(firstSnapshot.0, secondSnapshot.0)
        XCTAssertEqual(firstSnapshot.1, secondSnapshot.1)
        XCTAssertEqual(firstSnapshot.2, secondSnapshot.2)
    }

    // MARK: - v1.44 W1: local mode must survive a relaunch

    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cwa-\(UUID().uuidString)")!
    }

    /// The bug this pins: `isLocalMode` is a plain `@Published` with no
    /// backing store, so pre-W1 the mode lasted exactly one launch. On the
    /// next cold start `restoreSession()` finds no token (a local-mode user
    /// has none by design), falls into `.unavailable`, and landed on Settings
    /// — while `cli_pulse_onboarding_completed` kept the wizard suppressed.
    /// Net effect: choose "no account" once, get a signed-out shell forever.
    ///
    /// RED against pre-W1 `continueWithoutAccount()`, which wrote no key.
    func testContinueWithoutAccountPersistsMarkerSoTheChoiceSurvivesRelaunch() {
        let defaults = Self.isolatedDefaults()
        XCTAssertFalse(defaults.bool(forKey: AppState.localModeEnabledKey),
                       "precondition: fresh install has no marker")

        AppState().continueWithoutAccount(defaults: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppState.localModeEnabledKey),
                      "choosing local mode must persist, or the next launch silently reverts it")
    }

    /// Both arms pinned: a constant implementation fails one of them.
    func testColdLaunchLandingHonorsThePreviousChoice() {
        XCTAssertEqual(
            AppState.resolveColdLaunchLanding(localModePreviouslyChosen: true),
            .localMode,
            "a returning local-mode user must re-enter local mode, not the Sign-In form"
        )
        XCTAssertEqual(
            AppState.resolveColdLaunchLanding(localModePreviouslyChosen: false),
            .signIn,
            "a fresh install (or post-sign-out) must still land on Sign-In"
        )
    }

    /// Signing in is a later explicit choice and supersedes the marker.
    /// Without this, a signed-in user who later loses their Keychain entry
    /// would drop into local mode instead of being asked to sign in again.
    /// RED against pre-W1 `applyAuthenticatedState`, which left the key set.
    func testSigningInRetiresTheLocalModeMarker() {
        UserDefaults.standard.set(true, forKey: AppState.localModeEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: AppState.localModeEnabledKey) }

        let state = AppState()
        state.applyAuthenticatedState(
            AuthSessionState(userId: "u1", userName: "n", userEmail: "e@x.test", isPaired: false)
        )

        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppState.localModeEnabledKey),
                       "signing in must clear the persisted marker")
    }

    /// …but it must clear ONLY the marker, not the live flag.
    ///
    /// `MenuBarView` routes on `isLocalMode || isPaired`. A Mac that has just
    /// signed in is not yet paired, so forcing `isLocalMode = false` here
    /// bounces the user out of the tab shell into the pairing screen — and the
    /// user this hits is precisely the local-mode convert who was looking at a
    /// populated dashboard and clicked "sign in" to start syncing, i.e. the
    /// one person doing exactly what W1 wants. It also fixes itself a refresh
    /// tick later, which makes it a flicker rather than a stable state.
    ///
    /// Nothing needs the flag cleared: `RefreshRoute.decide` ignores
    /// `isLocalMode` once authenticated, and `refreshLocal` re-asserts
    /// `isLocalMode: true` in its payload. Ownership stays with the payload.
    func testSigningInDoesNotBounceALocalModeUserOutOfTheDashboard() {
        let state = AppState()
        state.isLocalMode = true

        state.applyAuthenticatedState(
            AuthSessionState(userId: "u1", userName: "n", userEmail: "e@x.test", isPaired: false)
        )

        XCTAssertTrue(
            state.isLocalMode || state.isPaired,
            "signing in from local mode on an unpaired Mac must keep MenuBarView on connectedView"
        )
    }

    /// The decision-to-effect wiring, which `resolveColdLaunchLanding` alone
    /// does not pin — that helper is a Bool→enum relabel, so testing it proves
    /// only that a mapping exists, not that anything acts on it. Deleting the
    /// call site in `restoreSession()` would otherwise leave the suite green
    /// while restoring the every-launch-signed-out-shell bug.
    func testColdLaunchLandingActuallyEntersLocalMode() {
        let state = AppState()
        state.isLocalMode = false
        state.selectedTab = .settings

        state.applyColdLaunchLanding(.localMode)

        XCTAssertTrue(state.isLocalMode, "the .localMode landing must actually enter local mode")
        XCTAssertEqual(state.selectedTab, .overview, "…and land on Overview, where the data is")
    }

    /// The other arm, so a `applyColdLaunchLanding` that ignored its argument
    /// and always entered local mode would fail here.
    func testColdLaunchLandingSignInGoesToSettings() {
        let state = AppState()
        state.isLocalMode = false
        state.selectedTab = .overview

        state.applyColdLaunchLanding(.signIn)

        XCTAssertEqual(state.selectedTab, .settings, "the .signIn landing must show the Sign-In form")
        XCTAssertFalse(state.isLocalMode, "the .signIn landing must not silently enter local mode")
    }

    /// Signing out is a request for the Sign-In form — it must not bounce
    /// back into local mode on the next launch.
    /// RED against pre-W1 `applySignedOutState`, which left the key set.
    func testSigningOutClearsTheLocalModeMarker() {
        UserDefaults.standard.set(true, forKey: AppState.localModeEnabledKey)
        defer { UserDefaults.standard.removeObject(forKey: AppState.localModeEnabledKey) }

        let state = AppState()
        state.applySignedOutState()

        XCTAssertFalse(UserDefaults.standard.bool(forKey: AppState.localModeEnabledKey),
                       "an explicit sign-out must not be undone by a stale local-mode marker")
    }
}
#endif
