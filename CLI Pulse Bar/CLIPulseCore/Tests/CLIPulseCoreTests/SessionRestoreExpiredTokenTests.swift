// 1.60: a cold launch whose stored access token has expired must not sign the
// user out.
//
// Supabase Auth answers an expired access token on `/auth/v1/user` with 403
// `bad_jwt`, not 401. Up to 1.60.0 `APIClient.me()` refreshed on 401 only, so
// the 403 was thrown, and `AuthManager.restoreSession` deleted both tokens on
// ANY error — the 403, but also no network yet, a timeout or a 5xx. These tests
// drive the real `AuthManager` + `APIClient` against a URLProtocol stub. The
// tokens go through the injected `persistTokens` closure (never the Keychain),
// and every assertion is on the request log — paths, order, Authorization —
// never on timing.

import Foundation
import XCTest
@testable import CLIPulseCore

final class SessionRestoreExpiredTokenTests: XCTestCase {

    private static let userPath = "/auth/v1/user"
    private static let tokenPath = "/auth/v1/token"
    private static let profilesPath = "/rest/v1/profiles"
    private static let tierPath = "/rest/v1/rpc/get_user_tier"

    private static let badJWT =
        #"{"code":403,"error_code":"bad_jwt","msg":"invalid JWT: unable to parse or verify signature, token has invalid claims: token is expired"}"#
    private static let user = #"{"id":"00000000-0000-0000-0000-000000000001","email":"someone@example.test"}"#
    private static let profiles = #"[{"paired":false,"name":"Someone","email":"someone@example.test"}]"#
    private static let rotated = #"{"access_token":"access-new","refresh_token":"refresh-2"}"#

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        super.tearDown()
    }

    // MARK: - 403 bad_jwt → one refresh → restored

    func test_an_expired_token_answered_403_bad_jwt_is_refreshed_once_and_the_session_restored() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"): return .status(403, Self.badJWT)
            case (Self.userPath, "access-new"): return .status(200, Self.user)
            case (Self.tokenPath, _): return .status(200, Self.rotated)
            case (Self.profilesPath, "access-new"): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .restored(let session) = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertEqual(session.userEmail, "someone@example.test")
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.tokenPath, Self.userPath, Self.profilesPath])
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "exactly one refresh")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-1"])
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"), "the rotated tokens are persisted")
        XCTAssertFalse(persisted.didDelete, "nothing is deleted")
        let held = await api.getToken()
        XCTAssertEqual(held, "access-new")
    }

    /// A token whose `exp` is already in the past is refreshed before it is
    /// sent, so a cold launch does not spend a round trip on a known 403.
    func test_a_token_already_past_its_exp_is_refreshed_before_it_is_sent() async throws {
        let expired = Self.jwt(exp: Date().addingTimeInterval(-3_600))
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-new"): return .status(200, Self.user)
            case (Self.userPath, _): return .status(403, Self.badJWT)
            case (Self.tokenPath, _): return .status(200, Self.rotated)
            case (Self.profilesPath, "access-new"): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: expired, refreshToken: "refresh-1")

        guard case .restored = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.userPath, Self.profilesPath],
                       "the expired token is never sent")
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"))
    }

    /// The same, the other way: a token that has not expired is sent as is.
    func test_a_token_still_inside_its_exp_is_sent_without_a_refresh() async throws {
        let fresh = Self.jwt(exp: Date().addingTimeInterval(3_600))
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, _, _) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: fresh, refreshToken: "refresh-1")

        guard case .restored = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.profilesPath])
    }

    // MARK: - A refusal still signs out

    func test_a_refresh_refused_with_refresh_token_not_found_signs_out() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(403, Self.badJWT)
            case Self.tokenPath:
                return .status(400, #"{"code":400,"error_code":"refresh_token_not_found","msg":"Invalid Refresh Token: Refresh Token Not Found"}"#)
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.tokenPath], "one refresh attempt, no loop")
        XCTAssertTrue(persisted.didDelete, "a refused session's tokens are deleted")
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertNil(access)
        XCTAssertNil(refresh)
    }

    /// Supabase's other refusals, and the older `invalid_grant` body.
    func test_the_refresh_endpoint_refusals_are_definitive_and_its_failures_to_answer_are_not() {
        for body in [
            #"{"error_code":"refresh_token_not_found"}"#,
            #"{"error_code":"refresh_token_already_used"}"#,
            #"{"error_code":"session_not_found"}"#,
            #"{"error_code":"session_expired"}"#,
            #"{"error_code":"user_not_found"}"#,
            #"{"error":"invalid_grant","error_description":"Invalid Refresh Token"}"#,
        ] {
            XCTAssertTrue(APIClient.isDefinitiveRefreshRejection(status: 400, body: body), body)
        }
        XCTAssertTrue(APIClient.isDefinitiveRefreshRejection(status: 401, body: #"{"message":"refresh token rejected"}"#))
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 403, body: "<html>Access denied</html>"),
                       "a firewall's page is not the auth server refusing the session")
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 408, body: "{}"))
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 503, body: "{}"))
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 502, body: "<html>Bad Gateway</html>"))
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 429, body: #"{"error_code":"over_request_rate_limit"}"#))
        XCTAssertFalse(APIClient.isDefinitiveRefreshRejection(status: 503, body: #"{"error_code":"session_not_found"}"#),
                       "a 5xx is never a refusal, whatever it carries")
    }

    // MARK: - No answer keeps the tokens

    func test_offline_on_me_keeps_the_tokens_and_does_not_sign_out() async throws {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .cannotFindHost] {
            SessionRestoreStub.reset()
            SessionRestoreStub.respond { _ in .fail(URLError(code)) }
            let (auth, api, persisted) = await Self.make()

            let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

            guard case .deferred = result else { return XCTFail("\(code): expected .deferred, got \(result)") }
            XCTAssertFalse(persisted.didDelete, "\(code): the tokens are kept")
            XCTAssertEqual(persisted.last, .init("access-old", "refresh-1"), "\(code)")
            XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0, "\(code): nothing to refresh")
            // Not signed in, so the client holds nothing it could send.
            let held = await api.getToken()
            XCTAssertNil(held, "\(code)")
        }
    }

    func test_a_5xx_keeps_the_tokens() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.userPath ? .status(503, "<html>Service Unavailable</html>") : .status(500)
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertFalse(persisted.didDelete)
        XCTAssertEqual(persisted.last, .init("access-old", "refresh-1"))
    }

    /// A 5xx from the refresh endpoint is no answer either: until 1.60.0 any
    /// non-2xx there cleared the tokens, exactly as a refusal does.
    func test_a_5xx_from_the_refresh_endpoint_keeps_the_tokens() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(403, Self.badJWT)
            case Self.tokenPath: return .status(503, "{}")
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertFalse(persisted.didDelete)
        XCTAssertEqual(persisted.last, .init("access-old", "refresh-1"))
    }

    func test_a_failed_profile_read_keeps_the_tokens() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(200, Self.user)
            case Self.profilesPath: return .status(500, "{}")
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertFalse(persisted.didDelete)
    }

    // MARK: - Only bad_jwt among 403s

    func test_a_403_that_is_not_bad_jwt_is_not_refreshed() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath: return .status(403, #"{"code":"42501","message":"permission denied"}"#)
            case Self.tokenPath: return .status(200, Self.rotated)
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath], "no refresh for a 403 that is not an expired token")
        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertFalse(persisted.didDelete)
    }

    func test_which_responses_reject_the_access_token() {
        XCTAssertTrue(APIClient.isRejectedAccessToken(status: 401, body: ""))
        XCTAssertTrue(APIClient.isRejectedAccessToken(status: 403, body: Self.badJWT))
        XCTAssertTrue(APIClient.isRejectedAccessToken(status: 403, body: #"{"error_code":"session_not_found"}"#))
        XCTAssertTrue(APIClient.isRejectedAccessToken(status: 403, body: #"{"error_code":"user_not_found"}"#))
        XCTAssertFalse(APIClient.isRejectedAccessToken(status: 403, body: #"{"error_code":"not_admin"}"#))
        XCTAssertFalse(APIClient.isRejectedAccessToken(status: 403, body: "<html>Forbidden</html>"))
        XCTAssertFalse(APIClient.isRejectedAccessToken(status: 400, body: Self.badJWT))
    }

    // MARK: - A concurrent refresh survives the restore

    /// The client already holds the tokens a concurrent refresh rotated in,
    /// while the restore was handed the older Keychain read. Installing that
    /// read would send a dead token and spend a used refresh token.
    func test_a_session_the_client_already_holds_is_not_replaced_by_the_older_keychain_read() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-new"): return .status(200, Self.user)
            case (Self.userPath, _): return .status(403, Self.badJWT)
            case (Self.tokenPath, _):
                return .status(400, #"{"code":400,"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#)
            case (Self.profilesPath, "access-new"): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make(holding: ("access-new", "refresh-2"))

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .restored = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.profilesPath])
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"))
        XCTAssertFalse(persisted.didDelete)
    }

    /// The race seen on iOS 1.59: `get_user_tier` gets a 401 and refreshes
    /// while the restore's `/auth/v1/user` gets its 403. The restore joins
    /// that refresh, or sees its result if it lands first (this test does not
    /// pin which; the next one pins the second order), instead of discarding
    /// it, and exactly one refresh request goes out.
    func test_a_refresh_a_concurrent_request_started_is_joined_not_discarded() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        let refreshArrived = expectation(description: "the tier request's refresh reached the server")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"):
                userSent.fulfill()
                return .held(403, Self.badJWT)
            case (Self.tierPath, "access-old"): return .status(401, #"{"code":"PGRST303","message":"JWT expired"}"#)
            case (Self.tierPath, "access-new"): return .status(200, #"{"tier":"free"}"#)
            case (Self.tokenPath, _):
                refreshArrived.fulfill()
                return .held(200, Self.rotated)
            case (Self.userPath, "access-new"): return .status(200, Self.user)
            case (Self.profilesPath, "access-new"): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let restore = Task {
            await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")
        }
        await fulfillment(of: [userSent], timeout: 5)
        let tier = Task { await api.serverTier() }
        await fulfillment(of: [refreshArrived], timeout: 5)
        SessionRestoreStub.releaseHeld(path: Self.userPath)   // the 403, while the refresh is out
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        let result = await restore.value
        let tierResult = await tier.value

        guard case .restored = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertNil(tierResult.error)
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "one refresh, shared")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-1"])
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.userPath), ["access-old", "access-new"])
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"), "the concurrent refresh's tokens are the ones kept")
        XCTAssertFalse(persisted.didDelete)
    }

    /// The other order: the concurrent refresh has already finished when the
    /// restore's 403 arrives. The restore retries with the token that refresh
    /// brought in and does not refresh again — a second refresh would spend
    /// the refresh token for nothing.
    func test_a_refresh_that_finished_while_the_403_was_out_is_used_without_a_second_refresh() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"):
                userSent.fulfill()
                return .held(403, Self.badJWT)
            case (Self.tierPath, "access-old"): return .status(401, #"{"code":"PGRST303","message":"JWT expired"}"#)
            case (Self.tierPath, "access-new"): return .status(200, #"{"tier":"free"}"#)
            case (Self.tokenPath, _): return .status(200, Self.rotated)
            case (Self.userPath, "access-new"): return .status(200, Self.user)
            case (Self.profilesPath, "access-new"): return .status(200, Self.profiles)
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let restore = Task {
            await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")
        }
        await fulfillment(of: [userSent], timeout: 5)
        let tierResult = await api.serverTier()
        XCTAssertNil(tierResult.error, "control: the concurrent request refreshed and succeeded")
        SessionRestoreStub.releaseHeld()
        let result = await restore.value

        guard case .restored = result else { return XCTFail("expected .restored, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "no second refresh")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.userPath), ["access-old", "access-new"])
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"))
        XCTAssertFalse(persisted.didDelete)
    }

    /// A sign-in that lands while the restore is out is not the restore's to
    /// undo, whatever the restore's own answer turns out to be.
    func test_a_session_installed_while_the_restore_was_out_is_left_alone() async throws {
        let userSent = expectation(description: "the restore's /auth/v1/user is out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"):
                userSent.fulfill()
                return .held(503, "{}")
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let restore = Task {
            await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")
        }
        await fulfillment(of: [userSent], timeout: 5)
        await api.updateToken("access-other")
        await api.updateRefreshToken("refresh-other")
        SessionRestoreStub.releaseHeld()
        let result = await restore.value

        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(access, "access-other")
        XCTAssertEqual(refresh, "refresh-other")
        XCTAssertNil(persisted.last, "the restore wrote nothing over the new session")
    }

    /// A restore that fails for no-answer reasons while another request's
    /// refresh is out must not take the session from under that refresh: its
    /// new tokens would be dropped and the spent refresh token kept.
    ///
    /// The 0.3 s wait can only make this test miss the bug, never fail it
    /// falsely: it gives the broken order (take first) time to finish.
    func test_a_failed_restore_waits_for_a_refresh_still_out_and_keeps_its_tokens() async throws {
        let profilesSent = expectation(description: "the restore's profile read is out")
        let refreshArrived = expectation(description: "the tier request's refresh reached the server")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"): return .status(200, Self.user)
            case (Self.profilesPath, _):
                profilesSent.fulfill()
                return .held(500, "{}")
            case (Self.tierPath, "access-old"): return .status(401, #"{"code":"PGRST303","message":"JWT expired"}"#)
            case (Self.tierPath, "access-new"): return .status(200, #"{"tier":"free"}"#)
            case (Self.tokenPath, _):
                refreshArrived.fulfill()
                return .held(200, Self.rotated)
            default: return .status(500)
            }
        }
        let (auth, api, persisted) = await Self.make()

        let restoreDone = expectation(description: "restore returned")
        let restore = Task {
            let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")
            restoreDone.fulfill()
            return result
        }
        await fulfillment(of: [profilesSent], timeout: 5)
        let tier = Task { await api.serverTier() }
        await fulfillment(of: [refreshArrived], timeout: 5)
        SessionRestoreStub.releaseHeld(path: Self.profilesPath)
        _ = await XCTWaiter().fulfillment(of: [restoreDone], timeout: 0.3)
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        let result = await restore.value
        _ = await tier.value

        guard case .deferred = result else { return XCTFail("expected .deferred, got \(result)") }
        XCTAssertEqual(persisted.last, .init("access-new", "refresh-2"),
                       "the refresh's tokens are kept, not the spent refresh-1")
        XCTAssertFalse(persisted.didDelete)
    }

    /// An unexpired token whose session is gone (signed out everywhere): GoTrue
    /// answers 403 `session_not_found`. The refresh gets the refusal, and the
    /// restore signs out instead of retrying a dead token.
    func test_a_token_whose_session_is_gone_ends_in_a_sign_out() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.userPath:
                return .status(403, #"{"code":403,"error_code":"session_not_found","msg":"Session from session_id claim in JWT does not exist"}"#)
            case Self.tokenPath:
                return .status(400, #"{"code":400,"error_code":"session_not_found","msg":"Session not found"}"#)
            default: return .status(500)
            }
        }
        let (auth, _, persisted) = await Self.make()

        let result = await auth.restoreSession(isDemoMode: false, accessToken: "access-old", refreshToken: "refresh-1")

        guard case .failed = result else { return XCTFail("expected .failed, got \(result)") }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.tokenPath])
        XCTAssertTrue(persisted.didDelete)
    }

    // MARK: - The app side of `.deferred`

    @MainActor
    func test_the_app_stays_out_of_the_account_keeps_the_tokens_and_tries_again() async throws {
        KeychainHelper.inMemoryStoreForTesting = [:]
        defer { KeychainHelper.inMemoryStoreForTesting = [:] }
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        defer { state.cancelDeferredSessionRestore() }

        await state.restoreSession()

        XCTAssertFalse(state.isAuthenticated, "not signed in before the account is confirmed")
        XCTAssertFalse(state.serverOnline)
        XCTAssertEqual(state.lastError, L10n.dashboard.serverOffline)
        XCTAssertEqual(state.storedToken, "access-old", "the tokens are kept")
        XCTAssertEqual(state.storedRefreshToken, "refresh-1")
        XCTAssertNotNil(state.deferredSessionRestoreTask, "another restore is scheduled")
        XCTAssertEqual(state.deferredSessionRestoreAttempts, 1)
    }

    @MainActor
    func test_the_app_signs_out_when_the_session_is_refused() async throws {
        KeychainHelper.inMemoryStoreForTesting = [:]
        defer { KeychainHelper.inMemoryStoreForTesting = [:] }
        SessionRestoreStub.respond { request in
            request.url?.path == Self.tokenPath
                ? .status(400, #"{"error_code":"refresh_token_not_found"}"#)
                : .status(403, Self.badJWT)
        }
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")

        await state.restoreSession()

        XCTAssertFalse(state.isAuthenticated)
        XCTAssertEqual(state.storedToken, "", "a refused session's tokens are deleted")
        XCTAssertNil(state.storedRefreshToken)
        XCTAssertNil(state.deferredSessionRestoreTask, "nothing left to retry")
    }

    func test_the_retry_backs_off_to_a_minute() {
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 1), 5)
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 2), 10)
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 3), 20)
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 4), 40)
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 5), 60)
        XCTAssertEqual(AppState.deferredSessionRestoreDelay(attempt: 1_000), 60)
    }

    // MARK: - The other Supabase Auth paths

    func test_linked_identities_refresh_on_403_bad_jwt() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-old"): return .status(403, Self.badJWT)
            case (Self.userPath, "access-new"): return .status(200, #"{"identities":[]}"#)
            case (Self.tokenPath, _): return .status(200, Self.rotated)
            default: return .status(500)
            }
        }
        let (_, api, _) = await Self.make(holding: ("access-old", "refresh-1"))

        let identities = try await api.userIdentities()

        XCTAssertEqual(identities, [])
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.tokenPath, Self.userPath])
    }

    /// Deleting the account refreshes first. A refresh that got no answer
    /// keeps the session (the user can retry); before 1.60 every failure was
    /// rethrown as `tokenExpired`, which signs out.
    func test_delete_account_with_a_5xx_refresh_is_not_a_session_expiry() async throws {
        SessionRestoreStub.respond { _ in .status(503, "{}") }
        let (_, api, _) = await Self.make(holding: ("access-old", "refresh-1"))

        do {
            try await api.deleteAccount()
            XCTFail("expected the delete to fail")
        } catch {
            XCTAssertNotEqual(DeleteAccountFailure.classify(error), .sessionExpired)
        }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath], "the RPC never goes out without a fresh token")
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(refresh, "refresh-1")
    }

    func test_jwt_expiry_reads_exp_and_nothing_else() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(APIClient.jwtExpiry(Self.jwt(exp: date)), date)
        XCTAssertNil(APIClient.jwtExpiry("access-old"))
        XCTAssertNil(APIClient.jwtExpiry("a.b.c"))
        XCTAssertNil(APIClient.jwtExpiry("a.\(Self.base64URL(#"{"sub":"x"}"#)).c"))
    }

    // MARK: - Helpers

    final class Persisted: @unchecked Sendable {
        struct Pair: Equatable {
            let access: String
            let refresh: String?
            init(_ access: String, _ refresh: String?) { self.access = access; self.refresh = refresh }
        }
        private let lock = NSLock()
        private var writes: [Pair] = []
        func record(_ access: String, _ refresh: String?) {
            lock.lock(); writes.append(Pair(access, refresh)); lock.unlock()
        }
        var last: Pair? { lock.lock(); defer { lock.unlock() }; return writes.last }
        var didDelete: Bool { lock.lock(); defer { lock.unlock() }; return writes.contains { $0.access.isEmpty } }
    }

    /// An `AuthManager` over a stubbed `APIClient`, wired like `AppState` does:
    /// rotations and the restore's own writes both land in `persisted`. By
    /// default the client starts empty, as at a cold launch, and the restore
    /// installs the session it is handed; `holding` pre-installs one.
    @MainActor
    private static func make(holding: (access: String, refresh: String?)? = nil) async -> (AuthManager, APIClient, Persisted) {
        let persisted = Persisted()
        let api = APIClient(token: holding?.access, supabaseURL: "https://stub.cli-pulse.test",
                            supabaseAnonKey: "anon", session: SessionRestoreStub.session())
        if let holding { await api.updateRefreshToken(holding.refresh) }
        await api.setTokenRefreshHandler { persisted.record($0, $1) }
        let auth = AuthManager(api: api) { persisted.record($0, $1) }
        return (auth, api, persisted)
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    private static func base64URL(_ json: String) -> String {
        Data(json.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func jwt(exp: Date) -> String {
        let header = base64URL(#"{"alg":"ES256","typ":"JWT"}"#)
        let payload = base64URL("{\"sub\":\"x\",\"exp\":\(Int(exp.timeIntervalSince1970))}")
        return "\(header).\(payload).signature"
    }
}

/// Records every request and answers it from `startLoading` without blocking.
/// `.held` answers are delivered only when the test calls `releaseHeld()`, on
/// the run loop `startLoading` ran on (CFNetwork calls every custom protocol
/// on one thread, so sleeping there would serialize all requests and hide any
/// concurrency).
final class SessionRestoreStub: URLProtocol {
    enum Answer {
        case status(Int, String = "{}")
        case fail(URLError)
        case held(Int, String)
    }
    typealias Responder = (URLRequest) -> Answer

    nonisolated(unsafe) private static var responder: Responder?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var held: [(path: String, runLoop: CFRunLoop, deliver: () -> Void)] = []
    private static let lock = NSLock()

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionRestoreStub.self]
        return URLSession(configuration: config)
    }

    static func respond(_ responder: @escaping Responder) {
        lock.lock(); defer { lock.unlock() }
        self.responder = responder
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        recorded = []
        held = []
    }

    /// Deliver the held answers — all of them, or only those for `path`.
    ///
    /// A responder fulfils its expectation before `startLoading` files the
    /// held answer, so the caller can get here first; wait (on the test's
    /// thread, never CFNetwork's) until there is something to release.
    static func releaseHeld(path: String? = nil) {
        let deadline = Date().addingTimeInterval(5)
        var pending: [(path: String, runLoop: CFRunLoop, deliver: () -> Void)] = []
        while pending.isEmpty, Date() < deadline {
            lock.lock()
            pending = held.filter { path == nil || $0.path == path }
            held.removeAll { path == nil || $0.path == path }
            lock.unlock()
            if pending.isEmpty { usleep(1_000) }
        }
        for entry in pending {
            CFRunLoopPerformBlock(entry.runLoop, CFRunLoopMode.commonModes.rawValue, entry.deliver)
            CFRunLoopWakeUp(entry.runLoop)
        }
    }

    static func requests() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func paths() -> [String] { requests().compactMap(\.url?.path) }

    static func count(_ path: String) -> Int { paths().filter { $0 == path }.count }

    static func authorizations(_ path: String) -> [String] {
        requests()
            .filter { $0.url?.path == path }
            .compactMap { $0.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) } }
    }

    static func refreshTokensSent() -> [String] {
        requests()
            .filter { $0.url?.path == "/auth/v1/token" }
            .compactMap { request in
                guard
                    let body = request.httpBody,
                    let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
                else { return nil }
                return object["refresh_token"] as? String
            }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var copy = request
        if copy.httpBody == nil, let stream = copy.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            stream.close()
            copy.httpBodyStream = nil
            copy.httpBody = data
        }
        Self.lock.lock()
        Self.recorded.append(copy)
        let responder = Self.responder
        Self.lock.unlock()

        let answer = responder?(copy) ?? .status(500)
        switch answer {
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let status, let body):
            deliver(status: status, body: body)
        case .held(let status, let body):
            let runLoop = CFRunLoopGetCurrent()!
            Self.lock.lock()
            Self.held.append((copy.url?.path ?? "", runLoop, { [weak self] in self?.deliver(status: status, body: body) }))
            Self.lock.unlock()
        }
    }

    private func deliver(status: Int, body: String) {
        guard let client else { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Data(body.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
