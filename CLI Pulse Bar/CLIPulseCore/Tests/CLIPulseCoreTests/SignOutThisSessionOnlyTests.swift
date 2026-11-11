// 1.63 (A1): Sign Out ends this device's session only.
//
// Up to 1.62 `APIClient.signOutServer` sent `POST /auth/v1/logout` with no
// `scope`, and Supabase Auth's default is `global`: one device's Sign Out
// revoked every session of the account. It also sent the access token as it
// was, so one that had expired (a Mac asleep, an iPhone not opened for an
// hour) was refused and nothing was revoked at all.
//
// These tests drive the real `APIClient` (and `AuthManager` where the Keychain
// matters) against `SessionRestoreStub`, which can hold an answer until the
// test releases it and can refuse a refresh. The fake tokens are made up here;
// `jwt(_:expiresIn:)` builds an unsigned JWT whose `exp` is all that is read.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class SignOutThisSessionOnlyTests: XCTestCase {

    private static let base = "https://stub.cli-pulse.test"
    private static let tokenPath = "/auth/v1/token"
    private static let logoutPath = "/auth/v1/logout"
    private static let tierPath = "/rest/v1/rpc/get_user_tier"

    private static let badJWT = #"{"code":403,"error_code":"bad_jwt","msg":"invalid JWT: token has invalid claims: token is expired"}"#
    private static let sessionNotFound = #"{"code":403,"error_code":"session_not_found","msg":"Session from session_id claim in JWT does not exist"}"#
    private static let notAdmin = #"{"code":403,"error_code":"not_admin","msg":"User not allowed"}"#
    private static let unauthorized = #"{"code":401,"error_code":"no_authorization","msg":"This endpoint requires a valid Bearer token"}"#
    private static let alreadyUsed = #"{"code":400,"error_code":"refresh_token_already_used","msg":"Invalid Refresh Token: Already Used"}"#

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
        SessionTokenStore.shared.resetForTesting()
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
        SessionTokenStore.shared.resetForTesting()
        super.tearDown()
    }

    // MARK: - scope=local, and an expired token refreshed for the revoke

    /// The stored access token has expired. The sign-out refreshes it with the
    /// session's own refresh token and revokes with the new access token. The
    /// refresh is the revoke's alone: nothing is installed in the client and
    /// nothing reaches `onTokenRefreshed` (the Keychain write).
    func test_an_expired_token_is_refreshed_with_its_own_refresh_token_and_revoked_with_the_new_one() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(200, Self.rotated("access-revoke", "refresh-revoke"))
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")
        AppState.persistAuthTokens(access: expired, refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)

        let fence = api.fenceCurrentSession()
        await auth.signOut(fence: fence, snapshot: SessionTokenStore.shared.revocationSnapshot())

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.logoutPath], "one refresh, then the logout")
        XCTAssertEqual(SessionRestoreStub.requests().first?.url?.query, "grant_type=refresh_token")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a"], "the session's own refresh token")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-revoke"])
        SessionRestoreStub.assertEveryLogoutIsLocal()
        XCTAssertEqual(rotations.count, 0, "the revoke's refresh never reaches onTokenRefreshed (the Keychain write)")
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertNil(access, "nothing installed")
        XCTAssertNil(refresh)
        XCTAssertNil(KeychainHelper.load(key: AppState.tokenKeychainKey), "nothing left in the Keychain")
        XCTAssertNil(KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey))
    }

    /// A token well inside its `exp` is sent as it is, and a 2xx ends it.
    func test_a_fresh_token_is_revoked_without_a_refresh() async throws {
        let fresh = Self.jwt("a", expiresIn: 3_600)
        SessionRestoreStub.respond { request in
            request.url?.path == Self.logoutPath ? .status(204, "") : .status(500)
        }
        let (api, _) = await Self.makeClient(access: fresh, refresh: "refresh-a")

        let removed = await api.signOutServer(fence: api.fenceCurrentSession(),
                                              snapshot: RevocationSnapshot(accessToken: fresh, refreshToken: "refresh-a"))

        XCTAssertEqual(removed, fresh)
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath], "no refresh for a token that is not expiring")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), [fresh])
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// Within a minute of its `exp` counts as expiring: the logout would most
    /// likely arrive after it.
    func test_a_token_within_a_minute_of_its_exp_is_refreshed_first() async throws {
        let closeToExpiry = Self.jwt("a", expiresIn: 30)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(200, Self.rotated("access-revoke", "refresh-revoke"))
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (api, _) = await Self.makeClient(access: closeToExpiry, refresh: "refresh-a")

        await api.signOutServer(fence: api.fenceCurrentSession(),
                                snapshot: RevocationSnapshot(accessToken: closeToExpiry, refreshToken: "refresh-a"))

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.logoutPath])
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-revoke"])
        XCTAssertTrue(APIClient.expiresWithinAMinute(closeToExpiry))
        XCTAssertFalse(APIClient.expiresWithinAMinute(Self.jwt("a", expiresIn: 3_600)))
        XCTAssertFalse(APIClient.expiresWithinAMinute("not-a-jwt"), "no readable exp: sent as it is")
    }

    // MARK: - The sign-out revokes the session it left, and only that one

    /// A signs out; B signs in before A's sign-out reaches the client. B is
    /// untouched (tokens, Keychain), B's refresh token goes nowhere, and A is
    /// revoked with the pair the app read at A's sign-out.
    func test_a_sign_out_that_reaches_the_client_after_a_new_sign_in_revokes_only_its_own_session() async throws {
        let expiredA = Self.jwt("a", expiresIn: -3_600)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(200, Self.rotated("access-a2", "refresh-a2"))
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expiredA, refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)
        AppState.persistAuthTokens(access: expiredA, refresh: "refresh-a")

        // The app signs out of A: the fence and the snapshot now, the rest later.
        let fenceA = api.fenceCurrentSession()
        let snapshotA = SessionTokenStore.shared.revocationSnapshot()
        // B signs in before A's sign-out reaches the client.
        await api.updateToken("access-b")
        await api.updateRefreshToken("refresh-b")
        AppState.persistAuthTokens(access: "access-b", refresh: "refresh-b")

        await auth.signOut(fence: fenceA, snapshot: snapshotA)

        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(access, "access-b", "B's session is untouched")
        XCTAssertEqual(refresh, "refresh-b")
        XCTAssertEqual(KeychainHelper.load(key: AppState.tokenKeychainKey), "access-b")
        XCTAssertEqual(KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey), "refresh-b")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a"], "A's captured refresh token, never B's")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a2"])
        XCTAssertFalse(SessionRestoreStub.requests().contains { Self.bearer($0) == "access-b" }, "B's token is sent nowhere")
        XCTAssertEqual(rotations.count, 0)
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// The same, and B is then signed out too before A's sign-out arrives. B
    /// is fenced by both sign-outs, but it was installed after A's: only B's
    /// own sign-out removes it (up to 1.62 any fenced session was taken by
    /// whichever sign-out came first).
    func test_a_session_signed_in_after_a_sign_out_is_removed_only_by_its_own_sign_out() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.logoutPath ? .status(204, "") : .status(500)
        }
        let (api, _) = await Self.makeClient(access: "access-a", refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)
        AppState.persistAuthTokens(access: "access-a", refresh: "refresh-a")
        let fenceA = api.fenceCurrentSession()
        let snapshotA = SessionTokenStore.shared.revocationSnapshot()
        await api.updateToken("access-b")
        await api.updateRefreshToken("refresh-b")
        AppState.persistAuthTokens(access: "access-b", refresh: "refresh-b")
        let fenceB = api.fenceCurrentSession()
        let snapshotB = SessionTokenStore.shared.revocationSnapshot()

        await auth.signOut(fence: fenceA, snapshot: snapshotA)

        let afterA = await api.getToken()
        XCTAssertEqual(afterA, "access-b", "A's sign-out does not take B, though B is fenced too")
        XCTAssertEqual(KeychainHelper.load(key: AppState.tokenKeychainKey), "access-b")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a"], "A is revoked with A's pair")

        await auth.signOut(fence: fenceB, snapshot: snapshotB)

        let afterB = await api.getToken()
        XCTAssertNil(afterB, "B's own sign-out removes it")
        XCTAssertNil(KeychainHelper.load(key: AppState.tokenKeychainKey))
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a", "access-b"])
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    // MARK: - No answer, or a refused refresh: the sign-out still happens here

    func test_offline_the_session_is_still_removed_and_one_logout_is_attempted() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")

        let removed = await api.signOutServer(fence: api.fenceCurrentSession(),
                                              snapshot: RevocationSnapshot(accessToken: expired, refreshToken: "refresh-a"))

        XCTAssertEqual(removed, expired, "removed from the client, and said so")
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertNil(access)
        XCTAssertNil(refresh)
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "one refresh attempt")
        XCTAssertEqual(SessionRestoreStub.count(Self.logoutPath), 1, "exactly one logout attempt")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), [expired], "the original token, as it is")
        XCTAssertEqual(rotations.count, 0)
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// The refresh token was already spent (another device of the same
    /// session, a refresh whose answer was lost): the refresh is refused, the
    /// logout goes out once with the original token, and that is all.
    func test_a_refresh_token_already_used_is_refused_and_the_original_token_is_sent_once() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(400, Self.alreadyUsed)
            case Self.logoutPath: return .status(403, Self.badJWT)
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")
        AppState.persistAuthTokens(access: expired, refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)

        await auth.signOut(fence: api.fenceCurrentSession(), snapshot: SessionTokenStore.shared.revocationSnapshot())

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.logoutPath],
                       "one refresh (refused), one logout, no second refresh after its bad_jwt")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), [expired])
        let access = await api.getToken()
        XCTAssertNil(access)
        XCTAssertNil(KeychainHelper.load(key: AppState.tokenKeychainKey), "signed out here all the same")
        XCTAssertNil(KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey))
        XCTAssertEqual(rotations.count, 0)
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    // MARK: - A refresh of the session being left, still out

    /// The order where the sign-out reaches the client while the session's
    /// ordinary refresh is still out: it waits, the refresh's pair is parked
    /// (never installed, persisted or returned), and the revoke uses it. No
    /// second refresh: the sign-out does not join the ordinary one or start
    /// its own with the spent refresh token.
    func test_a_refresh_still_out_when_the_sign_out_arrives_is_waited_for_and_its_pair_revoked() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        let refreshOut = expectation(description: "the ordinary refresh is out")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath:
                if SessionRestoreStub.count(Self.tokenPath) == 1 { refreshOut.fulfill() }
                return .held(200, Self.rotated("access-new", "refresh-new"))
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")
        AppState.persistAuthTokens(access: expired, refresh: "refresh-a")
        let writes = Writes()
        let auth = AuthManager(api: api) { writes.record($0, $1); AppState.persistAuthTokens(access: $0, refresh: $1) }
        let waiting = expectation(description: "the sign-out waits for the refresh")
        await api.setSignOutWaitHookForTesting { waiting.fulfill() }

        let refresh = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshOut], timeout: 5)
        let fence = api.fenceCurrentSession()
        let snapshot = SessionTokenStore.shared.revocationSnapshot()
        let signOut = Task { await auth.signOut(fence: fence, snapshot: snapshot) }
        await fulfillment(of: [waiting], timeout: 5)
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        await signOut.value

        do {
            _ = try await refresh.value
            XCTFail("the ordinary refresh's caller must not get the pair of a session the app left")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "the sign-out used that refresh's pair; no second refresh")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-new"])
        XCTAssertEqual(rotations.count, 0, "never installed: onTokenRefreshed never ran")
        XCTAssertFalse(writes.accessTokens.contains("access-new"), "never persisted")
        let access = await api.getToken()
        XCTAssertNil(access)
        XCTAssertNil(KeychainHelper.load(key: AppState.tokenKeychainKey))
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// The other order: the refresh comes back after the sign-out's fence but
    /// before its work reaches the client. Its pair is parked, its caller gets
    /// `CancellationError`, and the sign-out revokes with the parked pair.
    func test_a_refresh_that_came_back_after_the_fence_is_parked_for_the_sign_out() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        let refreshOut = expectation(description: "the ordinary refresh is out")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath:
                if SessionRestoreStub.count(Self.tokenPath) == 1 { refreshOut.fulfill() }
                return .held(200, Self.rotated("access-new", "refresh-new"))
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")
        AppState.persistAuthTokens(access: expired, refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)

        let refresh = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshOut], timeout: 5)
        let fence = api.fenceCurrentSession()
        let snapshot = SessionTokenStore.shared.revocationSnapshot()
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        do {
            _ = try await refresh.value
            XCTFail("the ordinary refresh's caller must not get the pair of a session the app left")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let held = await api.getToken()
        XCTAssertEqual(held, expired, "control: the rotation was not installed")
        XCTAssertEqual(KeychainHelper.load(key: AppState.tokenKeychainKey), expired, "nor persisted")
        XCTAssertEqual(rotations.count, 0)

        await auth.signOut(fence: fence, snapshot: snapshot)

        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "the spent refresh-a is not sent again")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-new"])
        let access = await api.getToken()
        XCTAssertNil(access)
        XCTAssertNil(KeychainHelper.load(key: AppState.tokenKeychainKey))
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// A refresh started for session A is not joined by a caller of session B,
    /// installed while it was out: B's caller gets B's own refresh, A's caller
    /// gets nothing, and only B's rotation is written and sent.
    func test_a_caller_of_a_newer_session_never_receives_the_older_sessions_pair() async throws {
        let refreshAOut = expectation(description: "A's refresh is out")
        let refreshBOut = expectation(description: "B's own refresh went out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.refreshToken(in: request)) {
            case (Self.tokenPath, "refresh-a"):
                refreshAOut.fulfill()
                return .held(200, Self.rotated("access-a2", "refresh-a2"))
            case (Self.tokenPath, "refresh-b"):
                refreshBOut.fulfill()
                return .status(200, Self.rotated("access-b2", "refresh-b2"))
            case (Self.tierPath, _):
                return .status(200, #"{"tier":"free"}"#)
            default:
                return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: "access-a", refresh: "refresh-a")

        let refreshA = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshAOut], timeout: 5)
        // B signs in while A's refresh is out.
        await api.updateToken("access-b")
        await api.updateRefreshToken("refresh-b")
        let refreshB = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshBOut], timeout: 5)
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)

        let resultB = try await refreshB.value
        do {
            _ = try await refreshA.value
            XCTFail("A's caller gets no pair for a session that is gone")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(resultB.accessToken, "access-b2", "B's caller gets B's own refresh, not A's pair")
        XCTAssertEqual(rotations.accessTokens, ["access-b2"], "only B's rotation reaches onTokenRefreshed (the Keychain write)")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a", "refresh-b"])
        let held = await api.getToken()
        XCTAssertEqual(held, "access-b2")
        _ = await api.serverTier()
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.tierPath), ["access-b2"], "the next request carries B's token")
    }

    // MARK: - One refresh, one retry

    func test_a_logout_answered_401_gets_one_refresh_and_one_retry() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.logoutPath, "access-a"): return .status(401, Self.unauthorized)
            case (Self.logoutPath, "access-new"): return .status(204, "")
            case (Self.tokenPath, _): return .status(200, Self.rotated("access-new", "refresh-new"))
            default: return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: "access-a", refresh: "refresh-a")

        await api.signOutServer(fence: api.fenceCurrentSession(),
                                snapshot: RevocationSnapshot(accessToken: "access-a", refreshToken: "refresh-a"))

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath, Self.tokenPath, Self.logoutPath],
                       "401: one refresh, then one retry")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a", "access-new"])
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a"])
        XCTAssertEqual(rotations.count, 0)
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    /// A clock running behind lets a token past its `exp` look valid here; the
    /// server answers 403 `bad_jwt`.
    func test_a_logout_answered_403_bad_jwt_gets_one_refresh_and_one_retry() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.logoutPath, "access-a"): return .status(403, Self.badJWT)
            case (Self.logoutPath, "access-new"): return .status(204, "")
            case (Self.tokenPath, _): return .status(200, Self.rotated("access-new", "refresh-new"))
            default: return .status(500)
            }
        }
        let (api, _) = await Self.makeClient(access: "access-a", refresh: "refresh-a")

        await api.signOutServer(fence: api.fenceCurrentSession(),
                                snapshot: RevocationSnapshot(accessToken: "access-a", refreshToken: "refresh-a"))

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath, Self.tokenPath, Self.logoutPath],
                       "403 bad_jwt: one refresh, then one retry")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a", "access-new"])
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    func test_a_repeated_401_is_retried_once_only() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.logoutPath: return .status(401, Self.unauthorized)
            case Self.tokenPath: return .status(200, Self.rotated("access-new", "refresh-new"))
            default: return .status(500)
            }
        }
        let (api, _) = await Self.makeClient(access: "access-a", refresh: "refresh-a")

        await api.signOutServer(fence: api.fenceCurrentSession(),
                                snapshot: RevocationSnapshot(accessToken: "access-a", refreshToken: "refresh-a"))

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath, Self.tokenPath, Self.logoutPath],
                       "one retry only, and one refresh")
    }

    /// The pre-flight refresh (an expired token) is the sign-out's one: when
    /// it fails and the logout is then answered 401, there is no second.
    func test_a_failed_up_front_refresh_spends_the_budget() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(503, "{}")
            case Self.logoutPath: return .status(401, Self.unauthorized)
            default: return .status(500)
            }
        }
        let (api, _) = await Self.makeClient(access: expired, refresh: "refresh-a")

        await api.signOutServer(fence: api.fenceCurrentSession(),
                                snapshot: RevocationSnapshot(accessToken: expired, refreshToken: "refresh-a"))

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.logoutPath],
                       "no second refresh after the up-front one")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), [expired])
    }

    func test_session_not_found_and_other_refusals_are_not_retried() async throws {
        for body in [Self.sessionNotFound, Self.notAdmin] {
            SessionRestoreStub.reset()
            SessionRestoreStub.respond { request in
                switch request.url?.path {
                case Self.logoutPath: return .status(403, body)
                case Self.tokenPath: return .status(200, Self.rotated("access-new", "refresh-new"))
                default: return .status(500)
                }
            }
            let (api, _) = await Self.makeClient(access: "access-a", refresh: "refresh-a")

            await api.signOutServer(fence: api.fenceCurrentSession(),
                                    snapshot: RevocationSnapshot(accessToken: "access-a", refreshToken: "refresh-a"))

            XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath], "no refresh, no retry: \(body)")
        }
    }

    func test_which_logout_answers_get_one_refresh_and_one_retry() {
        XCTAssertEqual(APIClient.logoutAnswer(status: 204, body: ""), .revoked)
        XCTAssertEqual(APIClient.logoutAnswer(status: 200, body: "{}"), .revoked)
        XCTAssertEqual(APIClient.logoutAnswer(status: 401, body: Self.unauthorized), .tokenRejected,
                       "401: one refresh, then one retry")
        XCTAssertEqual(APIClient.logoutAnswer(status: 401, body: ""), .tokenRejected, "401: one refresh, then one retry")
        XCTAssertEqual(APIClient.logoutAnswer(status: 403, body: Self.badJWT), .tokenRejected)
        XCTAssertEqual(APIClient.logoutAnswer(status: 403, body: Self.sessionNotFound), .other, "already gone")
        XCTAssertEqual(APIClient.logoutAnswer(status: 401, body: #"{"error_code":"session_not_found"}"#), .other,
                       "session_not_found is read before the status")
        XCTAssertEqual(APIClient.logoutAnswer(status: 403, body: Self.notAdmin), .other)
        XCTAssertEqual(APIClient.logoutAnswer(status: 403, body: "<html>forbidden</html>"), .other)
        XCTAssertEqual(APIClient.logoutAnswer(status: 500, body: "{}"), .other)
        XCTAssertEqual(APIClient.logoutAnswer(status: 0, body: ""), .other)
    }

    // MARK: - Nothing to revoke

    /// A sign-out with no session anywhere (leaving Demo) sends nothing. Up to
    /// 1.62 it sent a logout with an empty bearer.
    func test_a_sign_out_with_no_session_sends_nothing() async throws {
        SessionRestoreStub.respond { _ in .status(204, "") }
        let api = APIClient(supabaseURL: Self.base, supabaseAnonKey: "anon", session: SessionRestoreStub.session())

        let removed = await api.signOutServer(fence: api.fenceCurrentSession(),
                                              snapshot: SessionTokenStore.shared.revocationSnapshot())

        XCTAssertNil(removed)
        XCTAssertTrue(SessionRestoreStub.requests().isEmpty)
    }

    func test_a_snapshot_reads_empty_as_none() {
        let snapshot = RevocationSnapshot(accessToken: "", refreshToken: "refresh-a")
        XCTAssertNil(snapshot.accessToken)
        XCTAssertEqual(snapshot.refreshToken, "refresh-a")
        XCTAssertNil(RevocationSnapshot(accessToken: nil, refreshToken: "").refreshToken)
    }

    // MARK: - Parked rotations belong to one session each (review MUST 1)

    /// A is fenced; B is installed; B refreshes, is fenced by its own sign-out,
    /// and its refresh comes back parked. A's delayed sign-out arrives first:
    /// it must leave B's rotation alone, or B's sign-out (whose access token
    /// has expired and whose old refresh token the server now refuses) could
    /// not revoke B. Up to the first 1.63 draft a single slot was taken and
    /// cleared by whichever sign-out came first.
    func test_a_delayed_sign_out_never_takes_another_sessions_parked_rotation() async throws {
        let expiredB = Self.jwt("b", expiresIn: -3_600)
        let refreshBOut = expectation(description: "B's refresh is out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.refreshToken(in: request)) {
            case (Self.tokenPath, "refresh-b"):
                // The server takes a refresh token once.
                guard SessionRestoreStub.refreshTokensSent().filter({ $0 == "refresh-b" }).count == 1 else {
                    return .status(400, Self.alreadyUsed)
                }
                refreshBOut.fulfill()
                return .held(200, Self.rotated("access-b2", "refresh-b2"))
            case (Self.logoutPath, _):
                return .status(204, "")
            default:
                return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: "access-a", refresh: "refresh-a")
        let auth = AuthManager(api: api, persistTokens: AppState.persistAuthTokens)
        AppState.persistAuthTokens(access: "access-a", refresh: "refresh-a")

        // 1. A is fenced; its sign-out has not reached the client yet.
        let fenceA = api.fenceCurrentSession()
        let snapshotA = SessionTokenStore.shared.revocationSnapshot()
        // 2. B is installed.
        await api.updateToken(expiredB)
        await api.updateRefreshToken("refresh-b")
        AppState.persistAuthTokens(access: expiredB, refresh: "refresh-b")
        // 3. B refreshes.
        let refreshB = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshBOut], timeout: 5)
        // 4. B is fenced by its own sign-out.
        let fenceB = api.fenceCurrentSession()
        let snapshotB = SessionTokenStore.shared.revocationSnapshot()
        // 5. B's refresh comes back: parked for B's revocation.
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        do {
            _ = try await refreshB.value
            XCTFail("B's refresh caller gets no pair of a session signed out of")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let parked = await api.parkedRotationCountForTesting
        XCTAssertEqual(parked, 1, "control: B's rotation is parked")
        // 6. A's delayed sign-out arrives first.
        await auth.signOut(fence: fenceA, snapshot: snapshotA)
        // 7. Then B's.
        await auth.signOut(fence: fenceB, snapshot: snapshotB)

        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["access-a", "access-b2"],
                       "B's sign-out revokes with B's parked rotation")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-b"], "B's spent refresh token is not sent again")
        XCTAssertEqual(rotations.count, 0)
        let held = await api.getToken()
        XCTAssertNil(held)
        let left = await api.parkedRotationCountForTesting
        XCTAssertEqual(left, 0, "nothing parked once no revocation is pending")
        SessionRestoreStub.assertEveryLogoutIsLocal()
    }

    // MARK: - A flight is bound to its session (review MUST 2)

    /// A's flight is created; B is installed before the flight's task starts.
    /// The flight was captured with A's refresh token, finds A gone, and sends
    /// nothing. (Up to the first 1.63 draft the task read the refresh token
    /// when it started, and refreshed B under A's label.)
    func test_a_session_change_before_a_flight_starts_never_lets_it_spend_the_new_sessions_token() async throws {
        let started = expectation(description: "A's flight is about to start")
        let gate = Gate()
        SessionRestoreStub.respond { request in
            request.url?.path == Self.tokenPath ? .status(200, Self.rotated("access-x", "refresh-x")) : .status(500)
        }
        let (api, rotations) = await Self.makeClient(access: "access-a", refresh: "refresh-a")
        await api.setRefreshStageHookForTesting { stage in
            guard stage == .willStart else { return }
            started.fulfill()
            await gate.wait()
        }

        let refreshA = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [started], timeout: 5)
        await api.updateToken("access-b")
        await api.updateRefreshToken("refresh-b")
        gate.open()

        do {
            _ = try await refreshA.value
            XCTFail("A's caller gets no pair once A is gone")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertFalse(SessionRestoreStub.refreshTokensSent().contains("refresh-b"),
                       "an A-labelled flight never spends B's refresh token")
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0, "nothing sent for a session that is gone")
        let access = await api.getToken()
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(access, "access-b")
        XCTAssertEqual(refresh, "refresh-b")
        XCTAssertEqual(rotations.count, 0)
    }

    /// A's refresh finishes (installed and written while A was held); B signs
    /// in before A's caller resumes. That caller is not handed A's pair.
    func test_a_session_change_after_a_refresh_finished_keeps_its_pair_from_the_waiting_caller() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.tokenPath ? .status(200, Self.rotated("access-a2", "refresh-a2")) : .status(500)
        }
        let (api, rotations) = await Self.makeClient(access: "access-a", refresh: "refresh-a")
        await api.setRefreshStageHookForTesting { stage in
            guard stage == .didFinish else { return }
            await api.updateToken("access-b")
            await api.updateRefreshToken("refresh-b")
        }

        do {
            _ = try await api.refreshAccessToken()
            XCTFail("a waiter never receives the pair of a session that changed after the refresh")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(rotations.accessTokens, ["access-a2"], "control: A's refresh was written while A was held")
        let access = await api.getToken()
        XCTAssertEqual(access, "access-b")
    }

    // MARK: - The wait's deadline, cancellation, the network budget (review SHOULD)

    /// The refresh of the session being left does not come back in time. The
    /// revocation stops waiting at the (injected) deadline, stops observing
    /// the flight, and revokes with the access token as it is: it never
    /// refreshes with the refresh token the flight is spending. The flight's
    /// late answer lands nowhere.
    func test_a_wait_that_times_out_never_refreshes_with_the_token_being_spent() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        let refreshOut = expectation(description: "the ordinary refresh is out")
        let waiting = expectation(description: "the revocation waits for it")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath:
                guard SessionRestoreStub.count(Self.tokenPath) == 1 else { return .status(400, Self.alreadyUsed) }
                refreshOut.fulfill()
                return .held(200, Self.rotated("access-new", "refresh-new"))
            case Self.logoutPath:
                return .status(403, Self.badJWT)
            default:
                return .status(500)
            }
        }
        let (api, rotations) = await Self.makeClient(access: expired, refresh: "refresh-a")
        let deadlines = ManualDeadlines()
        await api.setDeadlineTriggerForTesting(deadlines.trigger)
        await api.setSignOutWaitHookForTesting { waiting.fulfill() }

        let refresh = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshOut], timeout: 5)
        let fence = api.fenceCurrentSession()
        let signOut = Task {
            await api.signOutServer(fence: fence, snapshot: RevocationSnapshot(accessToken: expired, refreshToken: "refresh-a"))
        }
        await fulfillment(of: [waiting], timeout: 5)
        XCTAssertEqual(deadlines.fire(APIClient.signOutRefreshWaitNanoseconds), 1, "control: the wait's deadline was armed")
        let removed = await signOut.value

        XCTAssertEqual(removed, expired)
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a"],
                       "a timed-out wait never refreshes with a token that is being spent")
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), [expired])
        let observers = await api.refreshObserverCountForTesting
        XCTAssertEqual(observers, 0, "the timed-out wait no longer observes the refresh")

        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        do {
            _ = try await refresh.value
            XCTFail("the late refresh hands its pair to nobody")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let parked = await api.parkedRotationCountForTesting
        XCTAssertEqual(parked, 0, "a late rotation with no revocation pending is not kept")
        XCTAssertEqual(rotations.count, 0)
        let held = await api.getToken()
        XCTAssertNil(held)
    }

    /// The task running the sign-out is cancelled while it waits: it stops
    /// observing the flight at once and starts no refresh of its own.
    func test_a_cancelled_sign_out_stops_observing_the_refresh() async throws {
        let expired = Self.jwt("a", expiresIn: -3_600)
        let refreshOut = expectation(description: "the ordinary refresh is out")
        let waiting = expectation(description: "the revocation waits for it")
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath:
                guard SessionRestoreStub.count(Self.tokenPath) == 1 else { return .status(400, Self.alreadyUsed) }
                refreshOut.fulfill()
                return .held(200, Self.rotated("access-new", "refresh-new"))
            case Self.logoutPath:
                return .status(204, "")
            default:
                return .status(500)
            }
        }
        let (api, _) = await Self.makeClient(access: expired, refresh: "refresh-a")
        let deadlines = ManualDeadlines()
        await api.setDeadlineTriggerForTesting(deadlines.trigger)
        await api.setSignOutWaitHookForTesting { waiting.fulfill() }

        let refresh = Task { try await api.refreshAccessToken() }
        await fulfillment(of: [refreshOut], timeout: 5)
        let fence = api.fenceCurrentSession()
        let signOut = Task {
            await api.signOutServer(fence: fence, snapshot: RevocationSnapshot(accessToken: expired, refreshToken: "refresh-a"))
        }
        await fulfillment(of: [waiting], timeout: 5)
        signOut.cancel()
        _ = await signOut.value

        let observers = await api.refreshObserverCountForTesting
        XCTAssertEqual(observers, 0, "a cancelled wait no longer observes the refresh")
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["refresh-a"], "and starts no refresh of its own")
        XCTAssertEqual(deadlines.armedCount, 0, "every deadline it armed is stopped")
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        _ = try? await refresh.value
    }

    /// A logout that never answers: the revocation ends at its network budget
    /// (an injected deadline), and the sign-out returns.
    func test_the_revocation_stops_at_its_network_budget() async throws {
        let logoutOut = expectation(description: "the logout is out")
        SessionRestoreStub.respond { request in
            guard request.url?.path == Self.logoutPath else { return .status(500) }
            logoutOut.fulfill()
            return .held(204, "")
        }
        let (api, _) = await Self.makeClient(access: "access-a", refresh: "refresh-a")
        let deadlines = ManualDeadlines()
        await api.setDeadlineTriggerForTesting(deadlines.trigger)

        let signOut = Task {
            await api.signOutServer(fence: api.fenceCurrentSession(),
                                    snapshot: RevocationSnapshot(accessToken: "access-a", refreshToken: "refresh-a"))
        }
        await fulfillment(of: [logoutOut], timeout: 5)
        await Self.until { deadlines.armed(APIClient.revocationBudgetNanoseconds) == 1 }
        XCTAssertEqual(deadlines.fire(APIClient.revocationBudgetNanoseconds), 1, "control: the budget was armed")
        let removed = await signOut.value

        XCTAssertEqual(removed, "access-a", "the sign-out ends when the budget runs out")
        XCTAssertEqual(SessionRestoreStub.count(Self.logoutPath), 1)
        XCTAssertEqual(deadlines.armedCount, 0)
    }

    // MARK: - Callers of a refresh a sign-out overtook (review SHOULD)

    /// The Watch asks the iPhone for a token; the iPhone signs out while the
    /// refresh is out. The Watch is handed nothing, the iPhone shows no error,
    /// and the cancelled refresh is not read as a refused session.
    func test_a_sign_out_overtaking_the_Watchs_refresh_hands_the_Watch_nothing_and_shows_no_error() async throws {
        let refreshOut = expectation(description: "the refresh for the Watch is out")
        SessionRestoreStub.respond { request in
            guard request.url?.path == Self.tokenPath else { return .status(500) }
            refreshOut.fulfill()
            return .held(200, Self.rotated("access-a2", "refresh-a2"))
        }
        let (api, rotations) = await Self.makeAccountClient()
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        state.isAuthenticated = true
        state.userId = Self.userA

        let answer = Task { await state.refreshSessionForWatch() }
        await fulfillment(of: [refreshOut], timeout: 5)
        api.fenceCurrentSession()
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        let token = await answer.value

        XCTAssertNil(token, "the Watch is handed no token of the session being left")
        XCTAssertNil(state.lastError, "no error shown")
        XCTAssertTrue(state.isAuthenticated, "a cancelled refresh is not a refused session: nothing signs out here")
        XCTAssertEqual(rotations.count, 0)
    }

    /// A cloud refresh (the lease-backed reads the dashboard shows) gets 401s,
    /// and their token refresh is overtaken by a sign-out. The reads end in
    /// `CancellationError`, which shows nothing.
    func test_a_cloud_refresh_whose_token_refresh_a_sign_out_overtakes_shows_no_error() async throws {
        let refreshOut = expectation(description: "the reads' token refresh is out")
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case ("/auth/v1/health", _):
                return .status(200, "{}")
            case (Self.tokenPath, _):
                if SessionRestoreStub.count(Self.tokenPath) == 1 { refreshOut.fulfill() }
                return .held(200, Self.rotated("access-a2", "refresh-a2"))
            case (_, "access-a"):
                return .status(401, #"{"code":"PGRST301","message":"JWT expired"}"#)
            default:
                return .status(500)
            }
        }
        let (api, _) = await Self.makeAccountClient()
        let state = AppState(
            runtimeEnvironment: RefreshAfterSessionRestoreTests.refreshOnlyRuntime,
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        state.isAuthenticated = true
        state.isPaired = true
        state.userId = Self.userA
        XCTAssertEqual(state.refreshRoute, .cloud)

        let refresh = Task {
            await state.dataRefreshManager.refreshAll(context: state.refreshContext(), callbacks: state.refreshCallbacks())
        }
        await fulfillment(of: [refreshOut], timeout: 5)
        api.fenceCurrentSession()
        SessionRestoreStub.releaseHeld(path: Self.tokenPath)
        await refresh.value

        XCTAssertNil(state.lastError, "no error shown for a read the sign-out overtook")
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 1, "one refresh, shared, and none after the fence")
        XCTAssertFalse(SessionRestoreStub.requests().contains { Self.bearer($0) == "access-a2" },
                       "the left session's new token is sent nowhere")
    }

    // MARK: - Helpers

    private static let userA = "00000000-0000-0000-0000-0000000000a1"

    /// A client holding account A's session as a sign-in leaves it (user id
    /// set), with each rotation it would persist recorded.
    private static func makeAccountClient() async -> (APIClient, Rotations) {
        let api = APIClient(supabaseURL: base, supabaseAnonKey: "anon", session: SessionRestoreStub.session())
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "access-a", refreshToken: "refresh-a", userID: userA, transitionGeneration: 0)
        let rotations = Rotations()
        await api.setTokenRefreshHandler { rotations.record($0, $1) }
        return (api, rotations)
    }

    /// Deadlines the test fires by hand instead of waiting for them.
    final class ManualDeadlines: @unchecked Sendable {
        private struct Armed {
            let id: Int
            let nanoseconds: UInt64
            let fire: @Sendable () -> Void
        }
        private let lock = NSLock()
        private var armedDeadlines: [Armed] = []
        private var lastID = 0

        var trigger: APIClient.DeadlineTrigger {
            { [self] nanoseconds, fire in
                lock.lock()
                lastID += 1
                let id = lastID
                armedDeadlines.append(Armed(id: id, nanoseconds: nanoseconds, fire: fire))
                lock.unlock()
                return { [self] in
                    lock.lock()
                    armedDeadlines.removeAll { $0.id == id }
                    lock.unlock()
                }
            }
        }

        var armedCount: Int { lock.lock(); defer { lock.unlock() }; return armedDeadlines.count }

        func armed(_ nanoseconds: UInt64) -> Int {
            lock.lock(); defer { lock.unlock() }
            return armedDeadlines.filter { $0.nanoseconds == nanoseconds }.count
        }

        /// Fires every armed deadline of that length; returns how many.
        @discardableResult
        func fire(_ nanoseconds: UInt64) -> Int {
            lock.lock()
            let due = armedDeadlines.filter { $0.nanoseconds == nanoseconds }
            armedDeadlines.removeAll { $0.nanoseconds == nanoseconds }
            lock.unlock()
            due.forEach { $0.fire() }
            return due.count
        }
    }

    /// Holds whoever waits until the test opens it.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters.append(continuation)
                lock.unlock()
            }
        }

        func open() {
            lock.lock()
            isOpen = true
            let pending = waiters
            waiters = []
            lock.unlock()
            pending.forEach { $0.resume() }
        }
    }

    private static func until(seconds: TimeInterval = 5, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }


    final class Rotations: @unchecked Sendable {
        private let lock = NSLock()
        private var pairs: [(access: String, refresh: String)] = []
        func record(_ access: String, _ refresh: String) { lock.lock(); pairs.append((access, refresh)); lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return pairs.count }
        var accessTokens: [String] { lock.lock(); defer { lock.unlock() }; return pairs.map { $0.access } }
    }

    final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var writes: [(access: String, refresh: String?)] = []
        func record(_ access: String, _ refresh: String?) { lock.lock(); writes.append((access, refresh)); lock.unlock() }
        var accessTokens: [String] { lock.lock(); defer { lock.unlock() }; return writes.map { $0.access } }
    }

    /// A client holding the session `access`/`refresh`, installed before any
    /// sign-out, with each rotation it would persist recorded.
    private static func makeClient(access: String, refresh: String?) async -> (APIClient, Rotations) {
        let api = APIClient(supabaseURL: base, supabaseAnonKey: "anon", session: SessionRestoreStub.session())
        await api.updateToken(access)
        await api.updateRefreshToken(refresh)
        let rotations = Rotations()
        await api.setTokenRefreshHandler { rotations.record($0, $1) }
        return (api, rotations)
    }

    private static func rotated(_ access: String, _ refresh: String) -> String {
        "{\"access_token\":\"\(access)\",\"refresh_token\":\"\(refresh)\"}"
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    private static func refreshToken(in request: URLRequest) -> String? {
        guard
            let body = request.httpBody,
            let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        else { return nil }
        return object["refresh_token"] as? String
    }

    /// An unsigned, made-up JWT whose `exp` is `seconds` from now.
    private static func jwt(_ subject: String, expiresIn seconds: TimeInterval) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"sub\":\"\(subject)\",\"exp\":\(exp)}")).signature"
    }
}
