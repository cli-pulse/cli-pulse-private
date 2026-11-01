// 1.61: the iPhone app runs while the iPhone is locked.
//
// Since the Watch asks the iPhone for each new token (#732), its `sendMessage`
// wakes or launches the iPhone app in the background, often while the iPhone
// is locked. Its Keychain items are `WhenUnlockedThisDeviceOnly`, so then:
//   - a refresh that finished could not write its new pair, and the Keychain
//     kept a refresh token the server had already spent;
//   - a launch read the Keychain as empty, restored nothing, and stayed signed
//     out until the app was killed.
// `KeychainHelper.lockedForTesting` makes the in-memory Keychain behave as a
// locked one: nothing readable, writes and deletes fail.

import Foundation
import Security
import XCTest
@testable import CLIPulseCore

@MainActor
final class LockedKeychainTests: XCTestCase {

    private static let userPath = "/auth/v1/user"
    private static let tokenPath = "/auth/v1/token"
    private static let profilesPath = "/rest/v1/profiles"
    private static let badJWT = #"{"code":403,"error_code":"bad_jwt","msg":"token is expired"}"#
    private static let user = #"{"id":"00000000-0000-0000-0000-00000000000a","email":"a@example.test"}"#
    private static let profiles = #"[{"paired":false,"name":"Someone","email":"a@example.test"}]"#
    private static let rotated = #"{"access_token":"access-new","refresh_token":"refresh-2"}"#

    override func setUp() {
        super.setUp()
        Self.resetAll()
    }

    override func tearDown() {
        Self.resetAll()
        super.tearDown()
    }

    private static func resetAll() {
        SessionRestoreStub.reset()
        KeychainHelper.lockedForTesting = false
        KeychainHelper.lockedKeysForTesting = []
        KeychainHelper.inMemoryStoreForTesting = [:]
        SessionTokenStore.shared.resetForTesting()
        protectedDataAvailable.value = true
    }

    /// What the app's live check answers in these tests (on the iPhone it asks
    /// `UIApplication.isProtectedDataAvailable` each time).
    final class Flag: @unchecked Sendable { var value = true }
    private static let protectedDataAvailable = Flag()

    // MARK: - A rotation the locked Keychain refuses

    /// A refresh that started before the lock and finished after it (or one in
    /// a background wake): the server spent `refresh-1`. The new pair is kept,
    /// read in place of the Keychain's, and written once the iPhone unlocks.
    func test_a_rotation_the_locked_keychain_refuses_is_kept_and_written_on_unlock() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.tokenPath ? .status(200, Self.rotated) : .status(500)
        }
        let (state, api) = await Self.makeState()
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        await api.updateToken("access-old")
        await api.updateRefreshToken("refresh-1")

        KeychainHelper.lockedForTesting = true
        _ = try await api.refreshAccessToken()

        XCTAssertEqual(Self.rawKeychain(AppState.tokenKeychainKey), "access-old", "control: the write failed")
        XCTAssertEqual(state.storedToken, "access-new", "the new pair is what the app reads")
        XCTAssertEqual(state.storedRefreshToken, "refresh-2")

        KeychainHelper.lockedForTesting = false
        state.protectedDataDidBecomeAvailable()

        XCTAssertEqual(Self.rawKeychain(AppState.tokenKeychainKey), "access-new", "written on unlock")
        XCTAssertEqual(Self.rawKeychain(AuthManager.refreshTokenKeychainKey), "refresh-2")
        XCTAssertNil(SessionTokenStore.shared.unsavedPair)
    }

    /// The pair the Keychain refused is what the next restore presents: the
    /// spent `refresh-1` never goes out again.
    func test_a_restore_after_a_refused_write_presents_the_newest_refresh_token() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.tokenPath, _): return .status(200, #"{"access_token":"access-3","refresh_token":"refresh-3"}"#)
            case (Self.userPath, "access-3"): return .status(200, Self.user)
            case (Self.userPath, _): return .status(403, Self.badJWT)
            case (Self.profilesPath, _): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        KeychainHelper.lockedForTesting = true
        AppState.persistAuthTokens(access: "access-new", refresh: "refresh-2")   // refused
        KeychainHelper.lockedForTesting = false

        await state.restoreSession()
        state.stopRefreshLoop()

        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-2"])
        XCTAssertTrue(state.isAuthenticated)
        XCTAssertEqual(Self.rawKeychain(AuthManager.refreshTokenKeychainKey), "refresh-3")
        await state.dataRefreshManager.refreshTask?.value
    }

    // MARK: - No refresh while locked

    func test_no_refresh_starts_while_protected_data_is_unavailable() async throws {
        SessionRestoreStub.respond { _ in .status(200, Self.rotated) }
        let (_, api) = await Self.makeState()
        await api.updateToken("access-old")
        await api.updateRefreshToken("refresh-1")
        Self.protectedDataAvailable.value = false

        do {
            _ = try await api.refreshAccessToken()
            XCTFail("expected the refresh to be postponed")
        } catch {
            XCTAssertTrue(error is SessionRefreshPostponed, "\(error)")
        }
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0, "the refresh token is not spent")
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(refresh, "refresh-1", "the session is kept")
    }

    /// A postponed refresh is no answer, not a refusal: a restore defers and
    /// keeps the tokens.
    func test_a_restore_that_would_refresh_while_locked_defers_and_keeps_the_tokens() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.userPath ? .status(403, Self.badJWT) : .status(200, Self.rotated)
        }
        let (state, _) = await Self.makeState()
        defer { state.cancelDeferredSessionRestore() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        Self.protectedDataAvailable.value = false

        await state.restoreSession()

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0)
        XCTAssertEqual(state.storedToken, "access-old")
        XCTAssertEqual(state.storedRefreshToken, "refresh-1")
        XCTAssertNotNil(state.deferredSessionRestoreTask)
    }

    // MARK: - A launch while locked

    /// Blocker 1 of the #732 review: launched in the background while locked,
    /// the app read no tokens and took the "never signed in" branch. Now it
    /// defers, and signs in once the iPhone is unlocked.
    func test_a_launch_while_locked_defers_and_signs_in_on_unlock() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop(); state.cancelDeferredSessionRestore() }
        let clock = Clock()
        state.deferredSessionRestoreClock = { clock.now }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        KeychainHelper.lockedForTesting = true

        await state.restoreSession()

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 0, "nothing to send while locked")
        XCTAssertNotNil(state.deferredSessionRestoreTask, "deferred, not given up")

        KeychainHelper.lockedForTesting = false
        clock.now += 6
        state.protectedDataDidBecomeAvailable()
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask, "the unlock started a try")
        await retry.value
        state.stopRefreshLoop()

        XCTAssertTrue(state.isAuthenticated, "signed in once unlocked")
        await state.dataRefreshManager.refreshTask?.value
    }

    /// A deferred try that runs while locked (a background wake) keeps the
    /// restore deferred; up to 1.61 it read no token and gave up for good.
    func test_a_deferred_try_while_locked_does_not_give_up() async throws {
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        let (state, _) = await Self.makeState()
        defer { state.cancelDeferredSessionRestore() }
        let clock = Clock()
        state.deferredSessionRestoreClock = { clock.now }
        state.makeNetworkReturnMonitor = { NoNetworkMonitor() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        await state.restoreSession()
        XCTAssertNotNil(state.deferredSessionRestoreTask, "control: deferred offline")

        KeychainHelper.lockedForTesting = true
        clock.now += 6
        state.retryDeferredSessionRestoreNow()
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask)
        await retry.value

        XCTAssertNotNil(state.deferredSessionRestoreTask, "still deferred")
        XCTAssertEqual(state.deferredSessionRestoreAttempts, 2)
    }

    /// The Watch asking a signed-out iPhone that holds a session (or its
    /// unlock) starts a restore when none is out.
    func test_an_idle_signed_out_app_with_a_session_restores_when_asked() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        state.restoreSessionIfIdle()
        let task = try XCTUnwrap(state.idleSessionRestoreTask)
        await task.value
        state.stopRefreshLoop()

        XCTAssertTrue(state.isAuthenticated)
        await state.dataRefreshManager.refreshTask?.value
    }

    func test_an_idle_restore_is_not_started_in_demo_or_without_a_session() async {
        let (state, _) = await Self.makeState()
        state.restoreSessionIfIdle()
        XCTAssertNil(state.idleSessionRestoreTask, "no session stored")
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        state.enterDemoMode()
        state.restoreSessionIfIdle()
        XCTAssertNil(state.idleSessionRestoreTask, "Demo")
    }

    // MARK: - A refusal in a refresh for the Watch

    /// Should-fix 1 of the #732 review: the refresh the iPhone makes for the
    /// Watch is refused. The iPhone signs out, as a refusal inside a data
    /// refresh does, instead of looking signed in with no token.
    func test_a_refused_refresh_for_the_watch_signs_the_iphone_out() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            case Self.tokenPath: return .status(400, #"{"error_code":"refresh_token_already_used"}"#)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        await state.restoreSession()
        state.stopRefreshLoop()
        await state.dataRefreshManager.refreshTask?.value
        XCTAssertTrue(state.isAuthenticated, "control: signed in")

        let token = await state.refreshSessionForWatch()

        XCTAssertNil(token)
        XCTAssertFalse(state.isAuthenticated, "signed out")
        // The Keychain is cleared by the sign-out's task, after its logout call.
        let deadline = Date().addingTimeInterval(5)
        while !state.storedToken.isEmpty, Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(state.storedToken, "")
    }

    // MARK: - Review follow-ups

    func test_only_a_lock_reads_as_locked() {
        XCTAssertEqual(KeychainHelper.read(status: errSecSuccess, data: Data("t".utf8)), .value("t"))
        XCTAssertEqual(KeychainHelper.read(status: errSecSuccess, data: nil), .failed)
        XCTAssertEqual(KeychainHelper.read(status: errSecItemNotFound, data: nil), .absent)
        XCTAssertEqual(KeychainHelper.read(status: errSecInteractionNotAllowed, data: nil), .locked)
        XCTAssertEqual(KeychainHelper.read(status: errSecAuthFailed, data: nil), .failed,
                       "a denied Mac keychain prompt is not waited out")
        XCTAssertEqual(KeychainHelper.read(status: errSecUserCanceled, data: nil), .failed)
    }

    /// Only the refresh token can be read as locked (a lock between the two
    /// reads). The restore must not go ahead with no refresh token: that reads
    /// as a refused session and signs out for good.
    func test_a_restore_defers_when_only_the_refresh_token_is_locked() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.userPath ? .status(403, Self.badJWT) : .status(200, Self.rotated)
        }
        let (state, _) = await Self.makeState()
        defer { state.cancelDeferredSessionRestore() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        KeychainHelper.lockedKeysForTesting = [AuthManager.refreshTokenKeychainKey]

        await state.restoreSession()
        KeychainHelper.lockedKeysForTesting = []

        XCTAssertEqual(SessionRestoreStub.paths(), [], "nothing sent")
        XCTAssertNotNil(state.deferredSessionRestoreTask, "deferred")
        XCTAssertEqual(state.storedToken, "access-old", "nothing deleted")
        XCTAssertEqual(state.storedRefreshToken, "refresh-1")
    }

    func test_two_asks_in_one_turn_start_one_restore() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        state.restoreSessionIfIdle()
        let first = try XCTUnwrap(state.idleSessionRestoreTask)
        state.restoreSessionIfIdle()
        XCTAssertEqual(state.idleSessionRestoreTask, first, "the second ask joins the first")
        await first.value
        state.stopRefreshLoop()

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 1)
        await state.dataRefreshManager.refreshTask?.value
    }

    /// Each refresh asks for background time and gives it back, after the new
    /// pair is written.
    func test_a_refresh_holds_background_time_until_its_tokens_are_written() async throws {
        SessionRestoreStub.respond { _ in .status(200, Self.rotated) }
        let (state, api) = await Self.makeState()
        let log = Log()
        await api.setRefreshBackgroundTime {
            log.add("begin")
            return { log.add("end, keychain: \(KeychainHelper.load(key: AppState.tokenKeychainKey) ?? "-")") }
        }
        await api.updateToken("access-old")
        await api.updateRefreshToken("refresh-1")

        _ = try await api.refreshAccessToken()

        XCTAssertEqual(log.entries, ["begin", "end, keychain: access-new"])
        XCTAssertEqual(state.storedToken, "access-new")
    }

    /// The unlock (or the next foreground) refreshes a signed-in app whose
    /// last refresh failed, such as one postponed while locked.
    func test_the_unlock_refreshes_a_signed_in_app_whose_last_refresh_failed() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (state, _) = await Self.makeState()
        defer { state.stopRefreshLoop() }
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        await state.restoreSession()
        state.stopRefreshLoop()
        await state.dataRefreshManager.refreshTask?.value
        let before = state.dataRefreshManager.refreshTask
        state.lastError = "a refresh failed"

        state.protectedDataDidBecomeAvailable()

        XCTAssertNotNil(state.dataRefreshManager.refreshTask)
        XCTAssertNotEqual(state.dataRefreshManager.refreshTask, before, "a refresh was requested")
        await state.dataRefreshManager.refreshTask?.value
    }

    // MARK: - The wiring the app targets cannot test

    func test_the_iphone_wiring() throws {
        let auth = try Self.code("CLIPulseCore/Sources/CLIPulseCore/AuthManager.swift")
        let observe = try Self.section(auth, from: "func observeProtectedData()", to: "#endif")
        XCTAssertTrue(observe.contains("UIApplication.protectedDataDidBecomeAvailableNotification"))
        XCTAssertTrue(observe.contains("UIApplication.willEnterForegroundNotification"))
        XCTAssertEqual(observe.components(separatedBy: "self?.protectedDataDidBecomeAvailable()").count - 1, 2,
                       "the unlock and the next foreground both write and restore")
        let restore = try Self.section(auth, from: "public func restoreSession() async {", to: "let generation = sessionGeneration")
        XCTAssertTrue(restore.contains("BackgroundTime("), "a background launch's restore asks for time")

        let app = try Self.code("CLIPulseCore/Sources/CLIPulseCore/AppState.swift")
        let launch = try Self.section(app, from: "if runtime.capabilities.allowsCloudSessionRestore {", to: "await restoreSession()")
        let ios = try Self.section(launch, from: "#if os(iOS)", to: "#endif")
        XCTAssertTrue(ios.contains("observeProtectedData()"))
        XCTAssertNotNil(ios.range(of: #"setRotationPersistenceCheck \{\s*await MainActor\.run \{ UIApplication\.shared\.isProtectedDataAvailable \}"#,
                                  options: .regularExpression), "asked live, not cached")
        XCTAssertTrue(ios.contains("await api.setRefreshBackgroundTime {"))
        XCTAssertTrue(ios.contains("BackgroundTime(\"Token refresh\")"))

        let phone = try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
        let answer = try Self.section(phone, from: "func credentialAnswer(", to: "private func currentIdentity()")
        XCTAssertTrue(answer.contains("await state.refreshSessionForWatch()"))
        XCTAssertFalse(answer.contains("state.api.refreshAccessToken()"))
        let restoring = try Self.section(answer, from: "phoneState = .restoring", to: "return WatchCredentialRelay.answer")
        XCTAssertNotNil(restoring.range(of: #"\n\s*state\.restoreSessionIfIdle\(\)"#, options: .regularExpression))
        let handlers = try Self.section(phone, from: "extension PhoneSessionManager: WCSessionDelegate", to: "private struct SendableReply")
        let timed = handlers.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("let backgroundTime = BackgroundTime(")
        }
        XCTAssertEqual(timed.count, 2, "both Watch question handlers ask for background time")
    }

    // MARK: - Helpers

    final class Clock { var now: TimeInterval = 1_000 }

    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ entry: String) { lock.lock(); items.append(entry); lock.unlock() }
        var entries: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    final class NoNetworkMonitor: NetworkReturnWatching {
        func start(onReturn: @escaping @MainActor () -> Void) {}
        func cancel() {}
    }

    private static func makeState() async -> (AppState, APIClient) {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        await api.setTokenRefreshHandler { AppState.persistRotatedTokens(access: $0, refresh: $1) }
        let flag = protectedDataAvailable
        await api.setRotationPersistenceCheck { flag.value }
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        return (state, api)
    }

    /// What the Keychain itself holds, whatever the app reads.
    private static func rawKeychain(_ key: String) -> String? {
        KeychainHelper.inMemoryStoreForTesting["-|\(key)"]
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    private static func code(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }   // -> "CLI Pulse Bar"
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private static func section(_ source: String, from start: String, to end: String) throws -> Substring {
        let startRange = try XCTUnwrap(source.range(of: start), start)
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex), end)
        return source[startRange.lowerBound..<endRange.lowerBound]
    }
}
