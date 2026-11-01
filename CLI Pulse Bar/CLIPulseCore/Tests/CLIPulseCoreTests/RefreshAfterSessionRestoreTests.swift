// 1.61 (B2): the first refresh after a cold launch's session restore.
//
// The restore holds `isLoading` across `completeAuthenticatedSignIn`, so that
// helper's own `refreshAll()` — and any refresh that came in meanwhile — was
// skipped as `refresh_in_flight`, and on a Mac whose menu was not opened the
// first upload waited for the next scheduled refresh, up to 30 minutes.
//
// These drive the real `AppState.refreshAll()` down the cloud route against a
// stub whose health check fails at once: each refresh that runs makes exactly
// one `/auth/v1/health` request and stops there, and a skipped one makes none.
// So the request log counts refreshes, with no timing involved.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class RefreshAfterSessionRestoreTests: XCTestCase {

    private static let healthPath = "/auth/v1/health"

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        super.tearDown()
    }

    // MARK: - A cold launch's restore, end to end

    /// The real `restoreSession()`: it holds `isLoading` across
    /// `completeAuthenticatedSignIn`, whose own `refreshAll()` is skipped
    /// behind it. Exactly one refresh runs as soon as the restore returns,
    /// instead of none until the next scheduled one.
    func test_a_restored_session_refreshes_once_as_soon_as_the_restore_ends() async {
        KeychainHelper.inMemoryStoreForTesting = [:]
        defer { KeychainHelper.inMemoryStoreForTesting = [:] }
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case "/auth/v1/user":
                return .status(200, #"{"id":"00000000-0000-0000-0000-000000000001","email":"someone@example.test"}"#)
            case "/rest/v1/profiles":
                return .status(200, #"[{"paired":true,"name":"Someone","email":"someone@example.test"}]"#)
            default:
                return .fail(URLError(.notConnectedToInternet))
            }
        }
        let state = Self.state(signedIn: false)
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        await state.restoreSession()
        // The restore started the refresh loop. Stopped before anything else
        // runs, so neither its timer nor a sync notice from a helper running
        // on this Mac can add a refresh of its own.
        state.stopRefreshLoop()

        XCTAssertTrue(state.isAuthenticated, "restored")
        XCTAssertFalse(state.isLoading)
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 0,
                       "the restore's own refresh was skipped behind it")
        let paid = state.dataRefreshManager.refreshTask
        await paid?.value
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1, "one refresh right after the restore")
        await Self.settle()
        XCTAssertEqual(state.dataRefreshManager.refreshTask, paid, "and no other was requested")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1)
    }

    // MARK: - The restore is slower than the refresh at launch

    /// The case from the 1.60.1 release check: the refresh at launch is
    /// skipped behind the restore, and one runs as soon as the restore lets go.
    func test_a_refresh_skipped_behind_the_restore_runs_once_the_restore_ends() async {
        let state = Self.signedInState()

        state.isLoading = true                   // the restore, still out
        await state.refreshAll()                 // the refresh at launch
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 0, "skipped behind the restore")

        state.isLoading = false                  // the restore ends, signed in
        let paid = state.dataRefreshManager.refreshTask
        await paid?.value
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1, "one refresh right after the restore")

        await Self.settle()
        XCTAssertEqual(state.dataRefreshManager.refreshTask, paid, "and no other was requested")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1)
    }

    /// The restore's own `refreshAll()` and a timer tick or helper notice that
    /// came in meanwhile are both skipped; they owe one refresh between them.
    func test_several_refreshes_skipped_behind_the_restore_owe_one_refresh() async {
        let state = Self.signedInState()

        state.isLoading = true
        await state.refreshAll()
        await state.refreshAll()
        await state.refreshAll()
        state.isLoading = false
        let paid = state.dataRefreshManager.refreshTask
        await paid?.value
        await Self.settle()

        XCTAssertEqual(state.dataRefreshManager.refreshTask, paid, "one request")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1)
    }

    /// The owed refresh is paid once. A later spinner (pairing, an identity
    /// link) that skipped nothing does not run it again.
    func test_the_owed_refresh_is_run_once() async {
        let state = Self.signedInState()

        state.isLoading = true
        await state.refreshAll()
        state.isLoading = false
        let paid = state.dataRefreshManager.refreshTask
        await paid?.value

        state.isLoading = true
        state.isLoading = false
        await Self.settle()

        XCTAssertEqual(state.dataRefreshManager.refreshTask, paid, "not requested again")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1)
    }

    // MARK: - The restore is faster

    /// Nothing was skipped while the restore held the flag, so it owes
    /// nothing: the refresh at launch runs by itself, and is the only one.
    func test_a_restore_that_skipped_nothing_owes_no_refresh() async {
        let state = Self.signedInState()

        state.isLoading = true
        state.isLoading = false                  // the restore ends first
        XCTAssertNil(state.dataRefreshManager.refreshTask, "nothing was owed")

        await state.refreshAll()                 // then the refresh at launch
        await Self.settle()
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1, "no extra refresh")
    }

    /// A refresh skipped behind another refresh owes nothing: the one in
    /// flight brings the data, and its own end is no reason to run again.
    func test_a_refresh_skipped_behind_another_refresh_owes_nothing() async {
        let state = Self.signedInState()
        SessionRestoreStub.respond { _ in .held(200, "{}") }

        let first = Task { @MainActor in await state.refreshAll() }
        await Self.until { SessionRestoreStub.count(Self.healthPath) == 1 }
        XCTAssertTrue(state.isLoading, "the first refresh holds the flag")

        await state.refreshAll()                 // skipped behind it
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        SessionRestoreStub.releaseHeld()
        await first.value
        await Self.settle()

        XCTAssertFalse(state.isLoading)
        XCTAssertNil(state.dataRefreshManager.refreshTask, "nothing was owed")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 1)
    }

    // MARK: - Nothing to refresh

    /// A restore that ends signed out (or in Demo) has nothing to refresh,
    /// and does not carry the debt to the next sign-in either.
    func test_a_restore_that_ends_signed_out_runs_nothing() async {
        let state = Self.signedInState()

        state.isLoading = true
        await state.refreshAll()
        state.isAuthenticated = false            // the restore was refused
        state.isLoading = false
        await Self.settle()
        XCTAssertNil(state.dataRefreshManager.refreshTask)

        state.isAuthenticated = true             // a later sign-in
        state.isLoading = true
        state.isLoading = false
        await Self.settle()
        XCTAssertNil(state.dataRefreshManager.refreshTask, "the debt went with the session")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 0)
    }

    /// A sign-out while the restore still holds the flag: what was owed was
    /// that session's, and nothing is refreshed after the sign-out (on an
    /// iPhone that refresh would send the Watch an empty snapshot after the
    /// sign-out it was just told about).
    func test_a_sign_out_while_the_restore_holds_the_flag_cancels_what_was_owed() async {
        KeychainHelper.inMemoryStoreForTesting = [:]
        defer { KeychainHelper.inMemoryStoreForTesting = [:] }
        let state = Self.signedInState()

        state.isLoading = true
        await state.refreshAll()                 // skipped behind the restore
        state.signOut()                          // clears the flag, then signs out
        await Self.settle()

        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNil(state.dataRefreshManager.refreshTask, "nothing requested after the sign-out")
        XCTAssertEqual(SessionRestoreStub.count(Self.healthPath), 0)
    }

    // MARK: - Helpers

    /// Signed in on the cloud route (a paired Mac; every iPhone), with
    /// launch setup off: no Keychain, no helper, no timers. The runtime allows
    /// live collection and nothing else, so a refresh runs and reads nothing
    /// of this Mac's (the testing runtime would stop every refresh at
    /// `allowsLiveCollection`, and the production one reads the app group).
    private static func signedInState() -> AppState { state(signedIn: true) }

    private static func state(signedIn: Bool) -> AppState {
        let api = APIClient(token: "access", supabaseURL: "https://stub.cli-pulse.test",
                            supabaseAnonKey: "anon", session: SessionRestoreStub.session())
        let state = AppState(
            runtimeEnvironment: refreshOnlyRuntime,
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        if signedIn {
            state.isAuthenticated = true
            state.isPaired = true
            XCTAssertEqual(state.refreshRoute, .cloud)
        }
        return state
    }

    static let refreshOnlyRuntime = CLIPulseRuntimeEnvironment(
        channel: .production,
        bundleIdentifier: "test.refresh-after-session-restore",
        fixedUserHome: nil,
        resolvedFixedUserHome: nil,
        capabilities: .init(
            allowsTelemetry: false,
            allowsUnsandboxedMigration: false,
            allowsHelperRegistration: false,
            allowsPermissionSnapshot: false,
            allowsStoreKitBootstrap: false,
            allowsLiveCollection: true,
            allowsWidgetPublishing: false,
            allowsProductionCloudEndpoints: false,
            allowsPassiveDiscovery: false,
            allowsInMemoryDemoRendering: false,
            allowsBookmarkRestoration: false,
            allowsPetRestoration: false,
            allowsHelperManifestRefresh: false,
            allowsAppUpdateRefresh: false,
            allowsCurrencyNetworkRefresh: false,
            allowsCloudSessionRestore: false,
            allowsBackgroundActivityAssertion: false),
        allowsProductionCloudEndpoints: false,
        shouldResetQAExperience: false)

    /// Lets any refresh a request started run and finish.
    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    private static func until(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
