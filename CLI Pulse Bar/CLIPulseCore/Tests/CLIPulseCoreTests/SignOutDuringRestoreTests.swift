// 1.61: a session restore still out when the user signs in or out answers for
// a session the app has left.
//
// Up to 1.61 a deferred restore try that was out when the user signed out
// (leaving Demo, say) found an app that was neither signed in, in Demo nor in
// local mode, and signed it back in. A refresh it had out could also rotate the
// session after the sign-out read its token, write the new pair to the
// Keychain, and survive the sign-out there. These tests drive the real
// `AppState`, `AuthManager` and `APIClient` against `SessionRestoreStub`, with
// the in-memory Keychain and the app's own rotation handler.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class SignOutDuringRestoreTests: XCTestCase {

    private static let userPath = "/auth/v1/user"
    private static let tokenPath = "/auth/v1/token"
    private static let profilesPath = "/rest/v1/profiles"
    private static let logoutPath = "/auth/v1/logout"

    private static let badJWT = #"{"code":403,"error_code":"bad_jwt","msg":"token is expired"}"#
    private static let userA = #"{"id":"00000000-0000-0000-0000-00000000000a","email":"a@example.test"}"#
    private static let userB = #"{"id":"00000000-0000-0000-0000-00000000000b","email":"b@example.test"}"#
    private static let profiles = #"[{"paired":false,"name":"Someone","email":"a@example.test"}]"#
    private static let rotated = #"{"access_token":"access-new","refresh_token":"refresh-2"}"#

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
        super.tearDown()
    }

    // MARK: - Sign-out

    /// The restore's refresh is out when the user signs out, and lands before
    /// the sign-out's own work reaches the API client (the main thread is held
    /// here until it has, which is the order that used to keep the tokens).
    func test_a_sign_out_while_the_restore_refreshes_leaves_no_session_anywhere() async throws {
        let refreshArrived = expectation(description: "the restore's refresh reached the server")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath:
                // The first is the stored, expired token; any later one is held.
                return SessionRestoreStub.count(Self.userPath) == 1 ? .status(403, Self.badJWT) : .held(200, Self.userA)
            case Self.tokenPath:
                if SessionRestoreStub.count(Self.tokenPath) == 1 { refreshArrived.fulfill() }
                return .held(200, Self.rotated)
            case Self.profilesPath: return .status(200, Self.profiles)
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (state, api) = await Self.makeState()
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [refreshArrived], timeout: 5)
        state.signOut()
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        // Blocks the main thread, so the sign-out's task cannot reach the API
        // client before the refresh's answer has been handled off it.
        Self.blockMainThread { SessionRestoreStub.count(Self.userPath) >= 2 }
        await Self.until { SessionRestoreStub.count(Self.logoutPath) == 1 && state.storedToken.isEmpty }
        SessionRestoreStub.releaseHeld()
        await restore.value

        XCTAssertFalse(state.isAuthenticated, "still signed out")
        XCTAssertEqual(state.storedToken, "", "nothing left in the Keychain")
        XCTAssertNil(state.storedRefreshToken)
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertNil(access, "the client holds no token")
        XCTAssertNil(refresh)
        XCTAssertNil(state.deferredSessionRestoreTask, "nothing scheduled")
        XCTAssertNotEqual(state.lastError, L10n.dashboard.serverOffline)
    }

    /// #730's case: a deferred restore try is out, the user taps Try Demo and
    /// leaves Demo again, and then the try's answer comes back.
    func test_leaving_demo_while_a_restore_try_is_out_stays_signed_out() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath:
                userSent.fulfill()
                return .held(200, Self.userA)
            case Self.profilesPath: return .status(200, Self.profiles)
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (state, api) = await Self.makeState()
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [userSent], timeout: 5)
        state.enterDemoMode()
        state.signOut()
        await Self.until { SessionRestoreStub.count(Self.logoutPath) == 1 && state.storedToken.isEmpty }
        SessionRestoreStub.releaseHeld(path: Self.userPath)
        await restore.value

        XCTAssertFalse(state.isAuthenticated, "still signed out")
        XCTAssertFalse(state.isDemoMode)
        XCTAssertEqual(state.userId, "")
        XCTAssertEqual(state.storedToken, "")
        XCTAssertNil(state.storedRefreshToken)
        let access = await api.getToken()
        XCTAssertNil(access)
        XCTAssertNil(state.deferredSessionRestoreTask)
    }

    // MARK: - Sign-in

    /// The user signs in to another account while the restore's account read
    /// is out. The answer about the old session must not touch the new one:
    /// not its tokens, and not the client's user id.
    func test_a_sign_in_while_the_restore_is_out_wins() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"):
                userSent.fulfill()
                return .held(200, Self.userA)
            case (Self.tokenPath, _) where request.url?.query?.contains("grant_type=password") == true:
                return .status(200, #"{"access_token":"access-b","refresh_token":"refresh-b","user":\#(Self.userB)}"#)
            case (Self.profilesPath, _):
                return .status(200, #"[{"paired":false,"name":"B","email":"b@example.test"}]"#)
            default: return .status(500)
            }
        }
        let (state, api) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        let restore = Task { await state.restoreSession() }
        await fulfillment(of: [userSent], timeout: 5)
        await state.signInWithPassword(email: "b@example.test", password: "pw")
        state.stopRefreshLoop()
        XCTAssertEqual(state.userId, "00000000-0000-0000-0000-00000000000b", "control: signed in as B")
        SessionRestoreStub.releaseHeld(path: Self.userPath)
        await restore.value

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.userId, "00000000-0000-0000-0000-00000000000b")
        XCTAssertEqual(state.storedToken, "access-b")
        XCTAssertEqual(state.storedRefreshToken, "refresh-b")
        let access = await api.getToken()
        XCTAssertEqual(access, "access-b")
        let lease = await api.authorizationLease(expectedUserID: "00000000-0000-0000-0000-00000000000b")
        XCTAssertNotNil(lease, "the client's session is still B's, not A's")
    }

    // MARK: - The restore's own gate

    /// `isCurrent` turning false while the account read is out: the answer is
    /// dropped and nothing is written, though the client's session is the same.
    func test_a_restore_the_app_no_longer_wants_writes_nothing() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath:
                userSent.fulfill()
                return .held(200, Self.userA)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        let writes = Writes()
        let auth = AuthManager(api: api) { writes.record($0, $1) }
        var current = true

        let restore = Task {
            await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1",
                                      isCurrent: { current })
        }
        await fulfillment(of: [userSent], timeout: 5)
        current = false
        SessionRestoreStub.releaseHeld()
        let result = await restore.value

        guard case .superseded = result else { return XCTFail("expected .superseded, got \(result)") }
        XCTAssertEqual(writes.count, 0, "nothing written")
    }

    // MARK: - A restore still restores

    func test_a_restore_that_refreshes_signs_in_and_keeps_the_rotated_pair() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"): return .status(403, Self.badJWT)
            case (Self.userPath, "access-new"): return .status(200, Self.userA)
            case (Self.tokenPath, _): return .status(200, Self.rotated)
            case (Self.profilesPath, _): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, api) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        await state.restoreSession()
        state.stopRefreshLoop()

        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(state.userId, "00000000-0000-0000-0000-00000000000a")
        XCTAssertEqual(state.storedToken, "access-new")
        XCTAssertEqual(state.storedRefreshToken, "refresh-2")
        let access = await api.getToken()
        XCTAssertEqual(access, "access-new")
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1)
    }

    // MARK: - Helpers

    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [(String, String?)] = []
        func record(_ access: String, _ refresh: String?) { lock.lock(); writes.append((access, refresh)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return writes.count }
    }

    /// An app over a stubbed client, with the app's own rotation handler.
    private static func makeState() async -> (AppState, APIClient) {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        await api.setTokenRefreshHandler { AppState.persistRotatedTokens(access: $0, refresh: $1) }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        return (state, api)
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    /// Waits WITHOUT letting the main actor run anything else.
    private static func blockMainThread(seconds: TimeInterval = 5, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { usleep(1_000) }
        XCTAssertTrue(condition(), "the condition was never met")
    }

    private static func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
