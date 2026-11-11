// 1.61 (B1): a session has one refresher. The Watch's session that came from
// the iPhone is renewed by asking the iPhone; the Watch never sends its refresh
// token to the auth server (it does not hold one). A Watch that signed in on
// its own still refreshes itself. Nothing but the iPhone saying it is signed
// out ends a session from the iPhone.
//
// The APIClient tests drive the real client against `SessionRestoreStub` and
// assert on the request log, never on timing.

import Foundation
import XCTest
@testable import CLIPulseCore

final class WatchCredentialRelayTests: XCTestCase {

    private static let tokenPath = "/auth/v1/token"
    private static let userPath = "/auth/v1/user"
    private static let profilesPath = "/rest/v1/profiles"
    private static let alertsPath = "/rest/v1/alerts"
    private static let userID = "00000000-0000-0000-0000-000000000001"
    private static let user = #"{"id":"00000000-0000-0000-0000-000000000001","email":"someone@example.test"}"#
    private static let profiles = #"[{"paired":true,"name":"Someone","email":"someone@example.test"}]"#

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        super.tearDown()
    }

    // MARK: - APIClient: a session the iPhone renews

    /// The acceptance case. A 401 on the Watch's data call renews through the
    /// iPhone and retries with its token; no refresh reaches the auth server.
    func test_a_session_from_the_iPhone_is_renewed_by_the_iPhone_never_by_the_auth_server() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.alertsPath, "access-from-phone-2"): return .status(200, "[]")
            case (Self.alertsPath, _): return .status(401, #"{"message":"JWT expired"}"#)
            case (Self.tokenPath, _): return .status(200, #"{"access_token":"server","refresh_token":"server-r"}"#)
            default: return .status(500)
            }
        }
        let renewals = Counter()
        let api = await Self.phoneSession(access: "access-from-phone-1") {
            renewals.increment()
            return "access-from-phone-2"
        }

        _ = try await api.alerts()

        XCTAssertEqual(renewals.value, 1, "the iPhone was asked once")
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0, "the Watch never refreshed on its own")
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.alertsPath, Self.alertsPath])
        let held = await api.getToken()
        XCTAssertEqual(held, "access-from-phone-2")
        let refresh = await api.getRefreshToken()
        XCTAssertNil(refresh, "the Watch holds no refresh token for the iPhone's session")
    }

    /// The phone's refresh token handed over with its sign-in is not kept.
    func test_a_session_installed_with_a_renewer_drops_the_refresh_token_it_was_given() async {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        let installed = await api.installExternalAuthenticatedSession(
            accessToken: "a", refreshToken: "phones-refresh-token", userID: Self.userID,
            transitionGeneration: 1, renewer: { "b" }
        )
        XCTAssertTrue(installed)
        let refresh = await api.getRefreshToken()
        XCTAssertNil(refresh)
    }

    /// An iPhone that cannot be reached keeps the session: the error is passed
    /// on, the token stays, and nothing is sent to the auth server.
    func test_an_unreachable_iPhone_keeps_the_session_and_its_token() async throws {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.alertsPath: return .status(401, #"{"message":"JWT expired"}"#)
            default: return .status(500)
            }
        }
        let api = await Self.phoneSession(access: "access-from-phone-1") {
            throw WatchCredentialRelayError.waitingForPhone
        }

        do {
            _ = try await api.alerts()
            XCTFail("expected the renewal's error")
        } catch let error as WatchCredentialRelayError {
            XCTAssertEqual(error, .waitingForPhone)
        }

        let held = await api.getToken()
        XCTAssertEqual(held, "access-from-phone-1", "the session is kept")
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0)
        XCTAssertEqual(
            WatchCredentialRelay.restoreFailureAction(source: .phone, error: WatchCredentialRelayError.waitingForPhone),
            .showOffline,
            "a restore that failed this way stays signed in and deletes nothing"
        )
    }

    /// A restore (`me()`) of a session whose token is past its `exp` asks the
    /// iPhone before sending it.
    func test_a_restore_with_an_expired_token_asks_the_iPhone_first() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.userPath, "access-from-phone-2"): return .status(200, Self.user)
            case (Self.profilesPath, "access-from-phone-2"): return .status(200, Self.profiles)
            default: return .status(403, #"{"code":403,"error_code":"bad_jwt"}"#)
            }
        }
        let expired = Self.jwt(exp: Date().addingTimeInterval(-600))
        let api = APIClient(token: expired, supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        await api.setSessionRenewer { "access-from-phone-2" }

        let response = try await api.me()

        XCTAssertEqual(response.access_token, "access-from-phone-2")
        XCTAssertNil(response.refresh_token)
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath, Self.profilesPath], "the expired token is never sent")
    }

    /// A Watch that signed in on its own keeps refreshing itself.
    func test_the_Watchs_own_session_still_refreshes_with_its_refresh_token() async throws {
        SessionRestoreStub.respond { request in
            switch (request.url?.path, Self.bearer(request)) {
            case (Self.alertsPath, "own-2"): return .status(200, "[]")
            case (Self.alertsPath, _): return .status(401, #"{"message":"JWT expired"}"#)
            case (Self.tokenPath, _): return .status(200, #"{"access_token":"own-2","refresh_token":"own-r2"}"#)
            default: return .status(500)
            }
        }
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "own-1", refreshToken: "own-r1", userID: Self.userID, transitionGeneration: 1
        )

        _ = try await api.alerts()

        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["own-r1"])
        let refresh = await api.getRefreshToken()
        XCTAssertEqual(refresh, "own-r2")
    }

    /// A renewal that comes back after the session changed is installed nowhere.
    func test_a_renewal_that_returns_after_the_session_changed_is_dropped() async throws {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "p1", refreshToken: nil, userID: Self.userID, transitionGeneration: 1,
            renewer: {
                // Another sign-in lands while the iPhone is being asked.
                _ = await api.beginExternalAuthorizationTransition(generation: 2)
                _ = await api.installExternalAuthenticatedSession(
                    accessToken: "other-session", refreshToken: "r", userID: Self.userID, transitionGeneration: 2
                )
                return "late-token"
            }
        )
        let result = try await api.refreshAccessToken()
        XCTAssertEqual(result.accessToken, "late-token", "returned to its caller")
        let held = await api.getToken()
        XCTAssertEqual(held, "other-session", "and installed nowhere")
    }

    /// A token the iPhone sends replaces the held one in the same session, and
    /// only for a session the iPhone renews.
    func test_a_token_sent_by_the_iPhone_replaces_the_held_one_only_for_its_session() async {
        let api = await Self.phoneSession(access: "p1") { "unused" }
        let adopted = await api.adoptRenewedAccessToken("p2")
        XCTAssertTrue(adopted)
        let held = await api.getToken()
        XCTAssertEqual(held, "p2")

        let own = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await own.beginExternalAuthorizationTransition(generation: 1)
        _ = await own.installExternalAuthenticatedSession(
            accessToken: "own-1", refreshToken: "own-r1", userID: Self.userID, transitionGeneration: 1
        )
        let ownAdopted = await own.adoptRenewedAccessToken("p2")
        XCTAssertFalse(ownAdopted)
        let ownHeld = await own.getToken()
        XCTAssertEqual(ownHeld, "own-1")
    }

    /// A queued token that arrives after a newer one came by reply is ignored.
    func test_an_older_token_never_replaces_a_newer_one() async {
        let now = Date()
        let newer = Self.jwt(exp: now.addingTimeInterval(3_600))
        let older = Self.jwt(exp: now.addingTimeInterval(1_800))
        let api = await Self.phoneSession(access: newer) { "unused" }
        let adoptedOlder = await api.adoptRenewedAccessToken(older)
        XCTAssertFalse(adoptedOlder)
        let held = await api.getToken()
        XCTAssertEqual(held, newer)
        let newest = Self.jwt(exp: now.addingTimeInterval(5_400))
        let adoptedNewest = await api.adoptRenewedAccessToken(newest)
        XCTAssertTrue(adoptedNewest)
    }

    /// The renewer belongs to one session: the next one starts without it.
    func test_a_new_session_does_not_inherit_the_renewer() async throws {
        let api = await Self.phoneSession(access: "p1") { "p2" }
        _ = await api.beginExternalAuthorizationTransition(generation: 2)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: "own-1", refreshToken: "own-r1", userID: Self.userID, transitionGeneration: 2
        )
        let adopted = await api.adoptRenewedAccessToken("p3")
        XCTAssertFalse(adopted, "the Watch's own session is not renewed by the iPhone")

        // The same without a transition in between: installing the session
        // itself lets go of the old one's renewer.
        let direct = await Self.phoneSession(access: "p1") { "p2" }
        _ = await direct.installExternalAuthenticatedSession(
            accessToken: "own-1", refreshToken: "own-r1", userID: Self.userID, transitionGeneration: 1
        )
        let directAdopted = await direct.adoptRenewedAccessToken("p3")
        XCTAssertFalse(directAdopted)
        let directRefresh = await direct.getRefreshToken()
        XCTAssertEqual(directRefresh, "own-r1")
    }

    // MARK: - The record

    func test_the_session_record_round_trips_and_a_session_without_one_renews_itself() {
        let record = WatchSessionRecord(source: .phone, userID: Self.userID, name: "N", email: "e@example.test")
        XCTAssertEqual(WatchSessionRecord.stored(record.encoded), record)
        XCTAssertEqual(WatchSessionRecord.source(of: WatchSessionRecord.stored(record.encoded)), .phone)
        XCTAssertFalse(WatchSessionSource.phone.renewsItself)
        XCTAssertTrue(WatchSessionSource.watch.renewsItself)

        // Stored before 1.61, or unreadable: renewed here, as it was.
        for raw in [nil, "", "not json", #"{"source":"phone","userID":"  ","name":"","email":""}"#] {
            XCTAssertNil(WatchSessionRecord.stored(raw), "\(String(describing: raw))")
            XCTAssertEqual(WatchSessionRecord.source(of: WatchSessionRecord.stored(raw)), .watch)
        }
    }

    /// A session stored before 1.61 has no record. It is the iPhone's unless
    /// the iPhone last sent this Watch another account's data.
    func test_a_session_from_before_1_61_is_the_iPhones_when_its_account_is() throws {
        let token = Self.jwt(exp: Date(), sub: Self.userID)
        let inferred = try XCTUnwrap(WatchSessionRecord.resolve(
            stored: nil, accessToken: token, lastPhoneUserID: Self.userID.uppercased()))
        XCTAssertEqual(inferred.source, .phone)
        XCTAssertEqual(inferred.userID, Self.userID)

        XCTAssertNil(WatchSessionRecord.resolve(stored: nil, accessToken: token, lastPhoneUserID: "another-account"))
        // 1.61: no iPhone account kept is not another one (WatchUpgradeAndWaitTests).
        XCTAssertEqual(WatchSessionRecord.resolve(stored: nil, accessToken: token, lastPhoneUserID: nil)?.source, .phone)
        XCTAssertNil(WatchSessionRecord.resolve(stored: nil, accessToken: "opaque", lastPhoneUserID: Self.userID))

        // A written record wins.
        let own = WatchSessionRecord(source: .watch, userID: Self.userID)
        XCTAssertEqual(WatchSessionRecord.resolve(stored: own.encoded, accessToken: token, lastPhoneUserID: Self.userID), own)
    }

    /// A session from the iPhone is never ended by its restore, whatever the
    /// error; the Watch's own deletes only on the server's refusal.
    func test_a_restore_ends_only_the_Watchs_own_session_and_only_on_a_refusal() {
        for error: Error in [APIError.tokenExpired, APIError.httpError(status: 401, body: ""),
                             URLError(.notConnectedToInternet), WatchCredentialRelayError.waitingForPhone] {
            XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(source: .phone, error: error), .showOffline, "\(error)")
        }
        XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(source: .watch, error: APIError.tokenExpired), .deleteCredentials)
        XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(
            source: .watch, error: APIError.httpError(status: 401, body: "")), .deleteCredentials)
        XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(
            source: .watch, error: URLError(.notConnectedToInternet)), .keepCredentials)
        XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(
            source: .watch, error: WatchCredentialRelayError.waitingForPhone), .keepCredentials)
    }

    // MARK: - The iPhone's answer

    func test_the_iPhone_answers_with_its_access_token_for_the_same_account_only() {
        let signedIn = WatchCredentialRelay.PhoneState.signedIn(userID: Self.userID, accessToken: "t")
        XCTAssertEqual(WatchCredentialRelay.answer(for: signedIn, requestedUserID: Self.userID.uppercased()),
                       .accessToken("t", userID: Self.userID))
        XCTAssertEqual(WatchCredentialRelay.answer(for: signedIn, requestedUserID: ""),
                       .accessToken("t", userID: Self.userID))
        XCTAssertEqual(WatchCredentialRelay.answer(for: signedIn, requestedUserID: "someone-else"), .unavailable)
        XCTAssertEqual(
            WatchCredentialRelay.answer(for: .signedIn(userID: Self.userID, accessToken: ""), requestedUserID: ""),
            .unavailable
        )
        // A token whose `sub` is another account is never handed over as this one's.
        let foreign = Self.jwt(exp: Date().addingTimeInterval(3_600), sub: "someone-else")
        XCTAssertEqual(
            WatchCredentialRelay.answer(for: .signedIn(userID: Self.userID, accessToken: foreign), requestedUserID: ""),
            .unavailable
        )
        let own = Self.jwt(exp: Date().addingTimeInterval(3_600), sub: Self.userID)
        XCTAssertEqual(
            WatchCredentialRelay.answer(for: .signedIn(userID: Self.userID, accessToken: own), requestedUserID: ""),
            .accessToken(own, userID: Self.userID)
        )
    }

    /// Only an iPhone with nothing stored says it is signed out. One still
    /// restoring (offline launch, locked Keychain, Demo over a kept session)
    /// gives no answer.
    func test_only_an_iPhone_with_no_session_says_signed_out() {
        XCTAssertEqual(WatchCredentialRelay.answer(for: .signedOut, requestedUserID: Self.userID), .signedOut)
        XCTAssertEqual(WatchCredentialRelay.answer(for: .restoring, requestedUserID: Self.userID), .unavailable)
    }

    func test_the_iPhone_refreshes_before_answering_with_a_token_about_to_expire() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func plan(_ offset: TimeInterval, canPersist: Bool = true) -> WatchCredentialRelay.PhoneRenewal {
            WatchCredentialRelay.phoneRenewal(
                accessToken: Self.jwt(exp: now.addingTimeInterval(offset)), now: now, canPersist: canPersist)
        }
        XCTAssertEqual(plan(-1), .renewFirst)
        XCTAssertEqual(plan(299), .renewFirst)
        XCTAssertEqual(plan(301), .sendAsIs)
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: "opaque", now: now, canPersist: true), .sendAsIs)
    }

    /// A locked iPhone never refreshes for the Watch: the new tokens could not
    /// be saved and its own next launch would be refused. It hands over a
    /// token still valid, and otherwise gives no answer.
    func test_a_locked_iPhone_never_refreshes_for_the_Watch() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func plan(_ offset: TimeInterval) -> WatchCredentialRelay.PhoneRenewal {
            WatchCredentialRelay.phoneRenewal(
                accessToken: Self.jwt(exp: now.addingTimeInterval(offset)), now: now, canPersist: false)
        }
        XCTAssertEqual(plan(120), .sendAsIs, "still valid: handed over")
        XCTAssertEqual(plan(-1), .noAnswer, "expired: no answer, and no refresh")
        XCTAssertEqual(plan(3_600), .sendAsIs)
    }

    // MARK: - The wire

    func test_answers_round_trip_and_never_carry_a_refresh_token() throws {
        let identity = try XCTUnwrap(WatchSessionIdentity(userID: Self.userID, epoch: 7))
        for answer: WatchCredentialRelay.Answer in [.accessToken("t", userID: Self.userID), .signedOut, .unavailable] {
            let message = WatchCredentialRelay.message(for: answer, identity: identity)
            XCTAssertEqual(WatchCredentialRelay.answer(from: message), answer)
            XCTAssertNil(message["refresh_token"])
            XCTAssertEqual(message["session_epoch"] as? String, "7")
            XCTAssertEqual(message["user_id"] as? String, Self.userID)
        }
        let request = WatchCredentialRelay.request(userID: Self.userID)
        XCTAssertEqual(WatchCredentialRelay.requestedUserID(in: request), Self.userID)
        XCTAssertNil(WatchCredentialRelay.requestedUserID(in: ["cli_pulse_auth": true]))
    }

    /// Anything malformed is no answer, never a sign-out.
    func test_a_malformed_answer_is_unavailable_never_signed_out() {
        for message: [String: Any] in [
            [:],
            ["status": "signed_out"],                                   // not an answer
            [WatchCredentialRelay.answerKey: true],
            [WatchCredentialRelay.answerKey: true, "status": "ok"],     // no token
            [WatchCredentialRelay.answerKey: true, "status": "ok", "access_token": "t"],   // no account
            [WatchCredentialRelay.answerKey: true, "status": "weird"],
        ] {
            XCTAssertEqual(WatchCredentialRelay.answer(from: message), .unavailable, "\(message)")
        }
    }

    // MARK: - The Watch's side

    func test_the_Watch_installs_its_accounts_token_waits_otherwise_and_signs_out_only_when_told() {
        XCTAssertEqual(
            WatchCredentialRelay.watchAction(for: .accessToken("t", userID: Self.userID.uppercased()),
                                             currentUserID: Self.userID),
            .install(accessToken: "t")
        )
        XCTAssertEqual(
            WatchCredentialRelay.watchAction(for: .accessToken("t", userID: "other"), currentUserID: Self.userID),
            .wait
        )
        XCTAssertEqual(WatchCredentialRelay.watchAction(for: .unavailable, currentUserID: Self.userID), .wait)
        XCTAssertEqual(WatchCredentialRelay.watchAction(for: .signedOut, currentUserID: Self.userID), .signOut)
        let foreign = Self.jwt(exp: Date().addingTimeInterval(3_600), sub: "someone-else")
        XCTAssertEqual(
            WatchCredentialRelay.watchAction(for: .accessToken(foreign, userID: Self.userID), currentUserID: Self.userID),
            .wait, "a token whose sub is another account is not installed"
        )
    }

    func test_the_waiting_message_is_localized() {
        let store = LocaleOverrideStore.shared
        let previous = store.override
        defer { store.set(previous) }
        store.set("en")
        let english = WatchCredentialRelayError.waitingForPhone.errorDescription
        store.set("zh-Hans")
        let chinese = WatchCredentialRelayError.waitingForPhone.errorDescription
        XCTAssertEqual(chinese, "iPhone 解锁并在附近时，数据就会更新。")
        XCTAssertNotEqual(chinese, english)
        for locale in ["en", "zh-Hans", "zh-Hant", "ja", "ko", "es"] {
            XCTAssertNotNil(LocaleCatalogueProbe.ownValue("watch.waiting_for_phone", in: locale),
                            "\(locale) has no watch.waiting_for_phone")
        }
    }

    // MARK: - Helpers

    private static func phoneSession(
        access: String,
        renewer: @escaping APIClient.SessionRenewer
    ) async -> APIClient {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: access, refreshToken: "phones-refresh-token", userID: userID,
            transitionGeneration: 1, renewer: renewer
        )
        return api
    }

    private static func bearer(_ request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "Authorization").map { String($0.dropFirst("Bearer ".count)) }
    }

    private static func jwt(exp: Date, sub: String = "x") -> String {
        func base64URL(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        return "\(base64URL(#"{"alg":"ES256","typ":"JWT"}"#)).\(base64URL("{\"sub\":\"\(sub)\",\"exp\":\(Int(exp.timeIntervalSince1970))}")).signature"
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}

/// The app targets have no test target, so the places that wire the relay into
/// the Watch and the iPhone are pinned by reading their source. Each check
/// names the line whose loss would bring the shared refresh token back.
final class WatchCredentialRelayWiringTests: XCTestCase {

    /// The iPhone's sign-in installs a session the iPhone renews; a code typed
    /// on the Watch installs the Watch's own.
    func test_the_Watch_records_who_renews_each_kind_of_session() throws {
        let source = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let phoneAuth = try Self.section(source, from: "func applyWatchAuth(", to: "func signOut()")
        XCTAssertTrue(phoneAuth.contains("source: .phone"))
        XCTAssertTrue(phoneAuth.contains("refresh_token: nil"), "the iPhone's refresh token is not kept")
        let otp = try Self.section(source, from: "func verifyOTP(code: String) async", to: "func resetOTP()")
        XCTAssertTrue(otp.contains("source: .watch"))

        let commit = try Self.section(source, from: "private func commitAuthenticatedSession(", to: "private func applyRemoteLogout(")
        XCTAssertTrue(commit.contains("refreshToken: source.renewsItself ? response.refresh_token : nil"))
        XCTAssertTrue(commit.contains("makePhoneRenewer(userID:"))
        XCTAssertTrue(commit.contains("WatchSessionRecord.keychainKey"), "the source is kept with the Keychain items")

        // 1.63 (A1): the decision is `WatchSignOut`'s, driven in `WatchSignOutTests`
        // (a relayed session sends nothing); the Watch hands its sign-out to it.
        let signOut = try Self.section(source, from: "func signOut() {", to: "private func beginAuthTransition(")
        XCTAssertTrue(signOut.contains("WatchSignOut.captureAndClear("), "the iPhone's session is not revoked from the Watch")
        XCTAssertTrue(signOut.contains("await WatchSignOut.finish("))

        let renew = try Self.section(source, from: "private func renewFromPhone(", to: "private func adoptPhoneAccessToken(")
        XCTAssertTrue(renew.contains("authTransitionGate.canCommit(lease)"),
                      "an answer that arrives after another sign-in or sign-out is acted on by nobody")

        let restore = try Self.section(source, from: "private func restoreSession() async", to: "// MARK: - 1.61 (B1)")
        XCTAssertTrue(restore.contains("setSessionRenewer("), "a restored session from the iPhone asks the iPhone")
        XCTAssertTrue(restore.contains("commitPhoneSessionOffline("), "and is not signed out while it cannot")
        XCTAssertTrue(restore.contains("WatchSessionRecord.resolve("), "a session from before 1.61 is recognized")
    }

    /// The Watch never holds the iPhone's refresh token, even in memory.
    func test_the_Watch_session_manager_drops_the_refresh_token_it_is_sent() throws {
        let source = try Self.code("CLI Pulse Bar Watch/WatchSessionManager.swift")
        XCTAssertFalse(source.contains("userInfo[\"refresh_token\"]"))
        XCTAssertFalse(source.contains("pendingRefreshToken"))
    }

    /// The iPhone sends each rotation, answers both ways of asking, and says
    /// "signed out" only with a readable Keychain.
    func test_the_iPhone_forwards_rotations_and_answers_the_Watch() throws {
        let source = try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
        XCTAssertTrue(source.contains("name: .cliPulseDidRotateAccessToken"))
        XCTAssertNotNil(source.range(
            of: #"didReceiveMessage message: \[String: Any\],\s*replyHandler:"#, options: .regularExpression))
        XCTAssertTrue(source.contains("func session(_ session: WCSession, didReceiveUserInfo"))
        let answer = try Self.section(source, from: "func credentialAnswer(", to: "private func currentIdentity()")
        // The branch that says "signed out" is guarded by both checks.
        XCTAssertNotNil(answer.range(
            of: #"else if UIApplication\.shared\.isProtectedDataAvailable,\s*state\.storedSessionIsAbsent \{\s*(//[^\n]*\s*)*phoneState = \.signedOut"#,
            options: .regularExpression),
            "a locked iPhone, or one whose Keychain cannot be read, never says signed out")
        XCTAssertTrue(answer.contains("canPersist: UIApplication.shared.isProtectedDataAvailable"),
                      "a locked iPhone never refreshes for the Watch")
        XCTAssertTrue(answer.contains("state.storedSessionIsAbsent"), "signed out only when the Keychain says so")
        let auth = try Self.section(source, from: "func sendAuthToWatch(", to: "func sendCredentialsToWatch(")
        XCTAssertFalse(auth.contains("\"refresh_token\""), "the iPhone's refresh token never goes to the Watch")

        let app = try Self.code("CLIPulseCore/Sources/CLIPulseCore/AppState.swift")
        let installed = try Self.section(app, from: "await api.setTokenRefreshHandler {", to: "await restoreSession()")
        XCTAssertTrue(installed.contains("Self.persistRotatedTokens("))
        let auth2 = try Self.code("CLIPulseCore/Sources/CLIPulseCore/AuthManager.swift")
        let handler = try Self.section(auth2, from: "static func persistRotatedTokens(", to: "static func persistAuthTokens(")
        XCTAssertTrue(handler.contains("name: .cliPulseDidRotateAccessToken"))
        XCTAssertFalse(handler.contains("\"refresh_token\""), "the rotation notice carries no refresh token")
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
