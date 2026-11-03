// 1.61: three follow-ups from the real-device test of the Watch token relay
// (B1, iPhone and Apple Watch).
//
// 1. A Watch waiting for a locked iPhone kept sending the token the server had
//    refused: a round of four data requests every 20 to 60 seconds, each a
//    401. It now holds that token back (`RefusedTokenHold`): until it holds
//    another one or the hold runs out, a refresh only asks the iPhone.
// 2. A Watch upgraded over a build from before 1.61 read the iPhone's session
//    as its own. Holding no refresh token for it, its restore sent the
//    expired token once (403), could not refresh, deleted the session and
//    showed the sign-in screen while the iPhone was still signed in.
// 3. The waiting message read like a request to sign in again.
//
// The app targets have no test target: the decisions are pure functions or
// the real APIClient against `SessionRestoreStub`, and the Watch's wiring is
// pinned by reading its source.

import Foundation
import XCTest
@testable import CLIPulseCore

final class WatchUpgradeAndWaitTests: XCTestCase {

    private typealias Hold = WatchCredentialRelay.RefusedTokenHold

    private static let userID = "00000000-0000-0000-0000-000000000001"
    private static let otherUser = "00000000-0000-0000-0000-000000000002"
    private static let tokenPath = "/auth/v1/token"
    private static let userPath = "/auth/v1/user"
    private static let alertsPath = "/rest/v1/alerts"

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        super.tearDown()
    }

    // MARK: - 1. The refused token is not sent again while the Watch waits

    func test_a_refused_token_is_held_back_and_any_other_token_is_not() {
        let start = Date()
        let refused = Self.jwt(sub: Self.userID, expiresIn: -60)
        let fromPhone = Self.jwt(sub: Self.userID, expiresIn: 3_600)
        var hold = Hold()
        XCTAssertFalse(hold.holdsBack(refused, now: start), "nothing refused yet")

        hold.refused(refused, at: start)
        XCTAssertTrue(hold.holdsBack(refused, now: start.addingTimeInterval(20)))
        XCTAssertTrue(hold.holdsBack(refused, now: start.addingTimeInterval(Hold.firstHold - 1)))
        XCTAssertFalse(hold.holdsBack(fromPhone, now: start.addingTimeInterval(20)), "a token from the iPhone goes at once")
        XCTAssertFalse(hold.holdsBack(nil, now: start.addingTimeInterval(20)))
        XCTAssertFalse(hold.holdsBack("", now: start.addingTimeInterval(20)))

        // Run out, it is still the token that was refused.
        XCTAssertFalse(hold.holdsBack(refused, now: start.addingTimeInterval(Hold.firstHold)))
        XCTAssertTrue(hold.covers(refused))
        XCTAssertFalse(hold.covers(fromPhone))

        hold.clear()
        XCTAssertFalse(hold.holdsBack(refused, now: start.addingTimeInterval(20)))
        XCTAssertFalse(hold.covers(refused))
        hold.refused(refused, at: start)
        hold.refused(nil, at: start)
        XCTAssertFalse(hold.holdsBack(refused, now: start.addingTimeInterval(20)), "no token: nothing held")
    }

    func test_the_hold_is_bounded_and_longer_for_each_refusal_of_the_same_token() {
        let refused = Self.jwt(sub: Self.userID, expiresIn: -60)
        var hold = Hold()
        var now = Date()
        var expected = Hold.firstHold
        for refusal in 1...8 {
            hold.refused(refused, at: now)
            XCTAssertEqual(hold.refusals, refusal)
            XCTAssertTrue(hold.holdsBack(refused, now: now.addingTimeInterval(expected - 1)), "refusal \(refusal)")
            XCTAssertFalse(hold.holdsBack(refused, now: now.addingTimeInterval(expected)), "refusal \(refusal): bounded")
            now = now.addingTimeInterval(expected)
            expected = min(expected * 2, Hold.longestHold)
        }
        XCTAssertEqual(expected, Hold.longestHold)
        XCTAssertLessThanOrEqual(Hold.longestHold, 1_800, "never more than half an hour without trying the server")

        // Another token refused starts again from the first hold.
        let another = Self.jwt(sub: Self.userID, expiresIn: -30)
        hold.refused(another, at: now)
        XCTAssertEqual(hold.refusals, 1)
        XCTAssertFalse(hold.holdsBack(another, now: now.addingTimeInterval(Hold.firstHold)))
    }

    func test_a_token_past_its_expiry_counts_as_refused_and_one_whose_expiry_cannot_be_read_does_not() {
        XCTAssertTrue(WatchCredentialRelay.hasExpired(Self.jwt(sub: Self.userID, expiresIn: -1)))
        XCTAssertFalse(WatchCredentialRelay.hasExpired(Self.jwt(sub: Self.userID, expiresIn: 60)))
        XCTAssertFalse(WatchCredentialRelay.hasExpired("opaque"))
        XCTAssertFalse(WatchCredentialRelay.hasExpired(nil))
    }

    /// The Watch's refresh loop (`WatchAppState.refreshAll`) against the real
    /// client, ticking every 20 seconds while the iPhone is locked: the data
    /// endpoint sees the refused token once per hold, the iPhone is still
    /// asked on every tick, and the token it gives on unlock goes to the
    /// server on the very next tick.
    func test_a_waiting_Watch_sends_the_refused_token_once_per_hold_and_keeps_asking_the_iPhone() async throws {
        let refused = Self.jwt(sub: Self.userID, expiresIn: -60)
        let fromPhone = Self.jwt(sub: Self.userID, expiresIn: 3_600)
        SessionRestoreStub.respond { request in
            guard request.url?.path == Self.alertsPath else { return .status(500) }
            return request.value(forHTTPHeaderField: "Authorization") == "Bearer \(fromPhone)"
                ? .status(200, "[]")
                : .status(401, #"{"message":"JWT expired"}"#)
        }
        let phone = PhoneStub()
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: refused, refreshToken: nil, userID: Self.userID, transitionGeneration: 1,
            renewer: { try phone.answer() }
        )

        var hold = Hold()
        let start = Date()
        for tick in 0..<9 {   // three minutes, the iPhone locked
            await Self.watchRefresh(api, hold: &hold, now: start.addingTimeInterval(Double(tick) * 20))
        }
        XCTAssertEqual(SessionRestoreStub.count(Self.alertsPath), 0, "a token past its expiry is not sent at all")
        XCTAssertEqual(phone.asked, 9, "and the iPhone was asked on every tick")
        XCTAssertEqual(hold.refusals, 1)

        // The hold runs out: one try with the same token, then a longer hold.
        let later = start.addingTimeInterval(Hold.firstHold)
        await Self.watchRefresh(api, hold: &hold, now: later)
        await Self.watchRefresh(api, hold: &hold, now: later.addingTimeInterval(Hold.firstHold))
        XCTAssertEqual(SessionRestoreStub.count(Self.alertsPath), 1, "the hold is bounded")
        XCTAssertEqual(hold.refusals, 2)

        // Unlocked: the iPhone's token reaches the server on the next tick.
        phone.give(fromPhone)
        await Self.watchRefresh(api, hold: &hold, now: later.addingTimeInterval(Hold.firstHold + 20))
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.alertsPath).last, fromPhone)
        XCTAssertEqual(SessionRestoreStub.count(Self.alertsPath), 2)
        XCTAssertEqual(SessionRestoreStub.count(Self.tokenPath), 0, "the Watch never refreshes the iPhone's session")
        let held = await api.getToken()
        XCTAssertEqual(held, fromPhone)
        XCTAssertFalse(hold.holdsBack(held))
    }

    /// A token the server refused before its expiry (revoked, say) goes once,
    /// then is held back the same way.
    func test_an_unexpired_token_the_server_refused_is_sent_once_then_held_back() async {
        let refused = Self.jwt(sub: Self.userID, expiresIn: 1_800)
        SessionRestoreStub.respond { _ in .status(401, #"{"message":"JWT invalid"}"#) }
        let phone = PhoneStub()
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        _ = await api.installExternalAuthenticatedSession(
            accessToken: refused, refreshToken: nil, userID: Self.userID, transitionGeneration: 1,
            renewer: { try phone.answer() }
        )
        var hold = Hold()
        let start = Date()
        for tick in 0..<9 {
            await Self.watchRefresh(api, hold: &hold, now: start.addingTimeInterval(Double(tick) * 20))
        }
        XCTAssertEqual(SessionRestoreStub.count(Self.alertsPath), 1)
        XCTAssertEqual(phone.asked, 9)
    }

    func test_the_Watch_refresh_holds_a_refused_token_back_and_still_asks_the_iPhone() throws {
        let watch = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let refresh = try Self.section(watch, from: "func refreshAll() async {", to: "func startRefreshLoop()")
        let seeds = try XCTUnwrap(refresh.range(of:
            "if WatchCredentialRelay.hasExpired(held), !refusedTokenHold.covers(held) {\n                refusedTokenHold.refused(held)"))
        let holds = try XCTUnwrap(refresh.range(of: "if refusedTokenHold.holdsBack(held) {"))
        XCTAssertLessThan(seeds.lowerBound, holds.lowerBound, "an expired token is held back before it is sent")
        let asks = try XCTUnwrap(refresh.range(of: "_ = try? await api.refreshAccessToken()"))
        let server = try XCTUnwrap(refresh.range(of: "async let dashTask = api.dashboard()"))
        XCTAssertLessThan(holds.lowerBound, asks.lowerBound)
        XCTAssertLessThan(asks.lowerBound, server.lowerBound, "held back: the iPhone is asked, the server is not")
        XCTAssertTrue(refresh.contains("if sessionSource == .phone {"), "only a session the iPhone renews")
        let stillHeld = try XCTUnwrap(refresh.range(
            of: #"if refusedTokenHold\.holdsBack\(now\) \{[^}]*return\s*\}"#, options: .regularExpression),
            "still the refused token after asking: no request")
        XCTAssertTrue(refresh[stillHeld].contains("awaitingPhoneCredentials = true"), "and still waiting, so it asks again")
        XCTAssertTrue(refresh.contains("let sentToken = await api.getToken()"))
        XCTAssertTrue(refresh.contains(
            "if sessionSource == .phone, (error as? WatchCredentialRelayError) == .waitingForPhone {\n                refusedTokenHold.refused(sentToken)"))
        let success = try Self.section(String(refresh), from: "dashboard = fetchedDashboard", to: "} catch {")
        XCTAssertTrue(success.contains("refusedTokenHold.clear()"), "a refresh that worked ends the hold")

        let offline = try Self.section(watch, from: "private func commitPhoneSessionOffline(", to: "// MARK: - WCSession Fallback")
        XCTAssertTrue(offline.contains("refusedTokenHold.refused(accessToken)"),
                      "a restore that could not renew does not send the token again at once")
        let signOut = try Self.section(watch, from: "func signOut() {", to: "let revokesOnServer")
        XCTAssertTrue(signOut.contains("refusedTokenHold.clear()"))
        let transition = try Self.section(watch, from: "private func beginAuthTransition(", to: "let began = await api")
        XCTAssertTrue(transition.contains("refusedTokenHold.clear()"))
    }

    // MARK: - 2. Upgrading from a Watch build before 1.61

    /// What the device test's first run did, step by step: a session stored
    /// before 1.61, no record, no iPhone account kept, and only an access
    /// token (a 1.61 iPhone had sent its sign-in to the old Watch build,
    /// which then deleted its refresh token). It read as the Watch's own.
    func test_the_device_tests_upgraded_Watch_signed_out_because_it_took_the_iPhones_session_for_its_own() async throws {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.userPath
                ? .status(403, #"{"code":403,"error_code":"bad_jwt","msg":"invalid JWT: token is expired"}"#)
                : .status(500)
        }
        let expired = Self.jwt(sub: Self.userID, expiresIn: -3_600)

        // Before: `.watch`, no refresh token, no renewer. One 403 from
        // /auth/v1/user, no refresh attempt, the credentials deleted.
        let before = APIClient(token: expired, supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                               session: SessionRestoreStub.session())
        do {
            _ = try await before.me()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? APIError, .tokenExpired)
            XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(source: .watch, error: error), .deleteCredentials,
                           "the sign-in screen")
        }
        XCTAssertEqual(SessionRestoreStub.paths(), [Self.userPath], "exactly the device test's log")

        // Now: the same session is the iPhone's. Its restore asks the iPhone
        // (locked: no answer), sends nothing, and shows the waiting state.
        SessionRestoreStub.reset()
        let record = try XCTUnwrap(WatchSessionRecord.resolve(
            stored: nil, accessToken: expired, lastPhoneUserID: nil, hasRefreshToken: false))
        XCTAssertEqual(record.source, .phone)
        XCTAssertEqual(record.userID, Self.userID)
        let after = APIClient(token: expired, supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                              session: SessionRestoreStub.session())
        await after.setSessionRenewer { throw WatchCredentialRelayError.waitingForPhone }
        do {
            _ = try await after.me()
            XCTFail("expected no answer from a locked iPhone")
        } catch {
            XCTAssertEqual(error as? WatchCredentialRelayError, .waitingForPhone)
            XCTAssertEqual(WatchCredentialRelay.restoreFailureAction(source: record.source, error: error), .showOffline,
                           "signed in, waiting for the iPhone")
        }
        XCTAssertEqual(SessionRestoreStub.paths(), [], "the expired token is not sent")
    }

    func test_a_session_from_before_1_61_is_the_iPhones_unless_the_iPhone_is_on_another_account() {
        let token = Self.jwt(sub: Self.userID, expiresIn: 600)
        for (owner, hasRefresh) in [(nil, true), (nil, false), (Self.userID.uppercased(), true), (Self.userID, false)] as [(String?, Bool)] {
            let record = WatchSessionRecord.resolve(stored: nil, accessToken: token, lastPhoneUserID: owner,
                                                    hasRefreshToken: hasRefresh)
            XCTAssertEqual(record?.source, .phone, "owner \(owner ?? "none"), refresh token \(hasRefresh)")
            XCTAssertEqual(record?.userID, Self.userID)
        }
        // The Watch's own: the iPhone is on another account, or the token's
        // account cannot be read.
        for hasRefresh in [true, false] {
            XCTAssertNil(WatchSessionRecord.resolve(stored: nil, accessToken: token, lastPhoneUserID: Self.otherUser,
                                                    hasRefreshToken: hasRefresh))
            XCTAssertNil(WatchSessionRecord.resolve(stored: nil, accessToken: "opaque", lastPhoneUserID: nil,
                                                    hasRefreshToken: hasRefresh))
            XCTAssertNil(WatchSessionRecord.resolve(stored: nil, accessToken: Self.jwt(sub: " ", expiresIn: 600),
                                                    lastPhoneUserID: nil, hasRefreshToken: hasRefresh))
        }
    }

    /// A session recorded as the Watch's own that the Watch holds no refresh
    /// token for can only be renewed by the iPhone (a 1.61 build before this
    /// fix wrote such records for the case above).
    func test_a_recorded_own_session_without_a_refresh_token_is_renewed_by_the_iPhone() {
        let token = Self.jwt(sub: Self.userID, expiresIn: 600)
        let own = WatchSessionRecord(source: .watch, userID: Self.userID, name: "N", email: "e@example.test")
        for owner in [nil, Self.userID] as [String?] {
            XCTAssertEqual(
                WatchSessionRecord.resolve(stored: own.encoded, accessToken: token, lastPhoneUserID: owner, hasRefreshToken: false),
                WatchSessionRecord(source: .phone, userID: Self.userID, name: "N", email: "e@example.test"),
                "owner \(owner ?? "none")")
        }
        XCTAssertEqual(WatchSessionRecord.resolve(stored: own.encoded, accessToken: token, lastPhoneUserID: Self.otherUser,
                                                  hasRefreshToken: false), own, "the iPhone is on another account")
        XCTAssertEqual(WatchSessionRecord.resolve(stored: own.encoded, accessToken: token, lastPhoneUserID: nil,
                                                  hasRefreshToken: true), own, "it renews itself")
        let phone = WatchSessionRecord(source: .phone, userID: Self.userID)
        XCTAssertEqual(WatchSessionRecord.resolve(stored: phone.encoded, accessToken: token, lastPhoneUserID: Self.otherUser,
                                                  hasRefreshToken: true), phone)
    }

    /// The cost of reading an unrecorded session as the iPhone's: one the
    /// Watch signed in to by itself with an email code, while the iPhone app
    /// was signed out, is renewed by asking the iPhone, whose "signed out"
    /// ends it (the user signs in on the Watch once more; that session is then
    /// recorded as the Watch's own). The Watch app is a companion app, so an
    /// iPhone app is always there to answer.
    func test_an_unrecorded_session_with_its_own_refresh_token_is_still_the_iPhones_when_no_account_is_kept() throws {
        let token = Self.jwt(sub: Self.userID, expiresIn: 600)
        let record = try XCTUnwrap(WatchSessionRecord.resolve(stored: nil, accessToken: token, lastPhoneUserID: nil,
                                                              hasRefreshToken: true))
        XCTAssertEqual(record.source, .phone)
        XCTAssertEqual(WatchCredentialRelay.watchAction(for: .signedOut, currentUserID: Self.userID), .signOut)
        XCTAssertEqual(WatchCredentialRelay.answer(for: .signedOut, requestedUserID: Self.userID), .signedOut)
        let plist = try Self.code("CLI Pulse Bar Watch/Info.plist")
        XCTAssertTrue(plist.contains("<key>WKCompanionAppBundleIdentifier</key>"))
        XCTAssertFalse(plist.contains("WKRunsIndependentlyOfCompanionApp"))
    }

    func test_signing_out_revokes_only_a_session_the_Watch_renews_itself_as_a_restore_reads_it() throws {
        let watch = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let signOut = try Self.section(watch, from: "let revokesOnServer = (", to: ").renewsItself")
        XCTAssertTrue(signOut.contains("WatchSessionRecord.resolve("))
        XCTAssertTrue(signOut.contains("lastPhoneUserID: WatchSessionManager.shared.lastPhoneUserID,"))
        XCTAssertTrue(signOut.contains("hasRefreshToken: !(KeychainHelper.load(key: \"cli_pulse_refresh_token\") ?? \"\").isEmpty"))
        XCTAssertTrue(signOut.contains(")?.source ?? sessionSource"))
    }

    func test_the_restore_tells_resolve_whether_it_holds_a_refresh_token() throws {
        let watch = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let restore = try Self.section(watch, from: "private func restoreSession() async", to: "guard let lease = await beginAuthTransition(\n            kind: .sessionRestore")
        XCTAssertTrue(restore.contains("let refreshToken = KeychainHelper.load(key: \"cli_pulse_refresh_token\")"))
        XCTAssertTrue(restore.contains("lastPhoneUserID: WatchSessionManager.shared.lastPhoneUserID,\n            hasRefreshToken: !(refreshToken ?? \"\").isEmpty"))
        // The persisted names stay what every build reads.
        XCTAssertEqual(WatchSessionRecord.keychainKey, "cli_pulse_watch_session_record")
        let manager = try Self.code("CLI Pulse Bar Watch/WatchSessionManager.swift")
        XCTAssertTrue(manager.contains(#"private let ownerKey = "cli_pulse_watch_context_owner""#))
    }

    // MARK: - 3. The waiting message promises an update, not a sign-in

    func test_the_waiting_message_says_the_data_updates_and_asks_for_no_sign_in() {
        let expected = [
            "en": "Data will update once your iPhone is unlocked and nearby.",
            "zh-Hans": "iPhone 解锁并在附近时，数据就会更新。",
            "zh-Hant": "iPhone 解鎖並在附近時，資料就會更新。",
            "ja": "iPhone のロックが解除されて近くにあれば、データが更新されます。",
            "ko": "iPhone이 잠금 해제되어 가까이 있으면 데이터가 업데이트됩니다.",
            "es": "Los datos se actualizarán cuando tu iPhone esté desbloqueado y cerca.",
        ]
        let signIn = [
            "en": ["sign", "Open CLI Pulse"], "zh-Hans": ["登录", "打开"], "zh-Hant": ["登入", "開啟"],
            "ja": ["サインイン", "ログイン", "開いて"], "ko": ["로그인", "여세요"], "es": ["sesión", "Abre"],
        ]
        let store = LocaleOverrideStore.shared
        let previous = store.override
        defer { store.set(previous) }
        store.set("zh-Hans")
        XCTAssertEqual(WatchCredentialRelayError.waitingForPhone.errorDescription,
                       L10n.keepingBrandUnbroken(expected["zh-Hans"]!), "resolved in a non-English locale")
        for (locale, text) in expected {
            let own = LocaleCatalogueProbe.ownValue("watch.waiting_for_phone", in: locale)
            XCTAssertEqual(own, L10n.keepingBrandUnbroken(text), locale)
            for word in signIn[locale] ?? [] {
                XCTAssertFalse(own?.contains(word) ?? true, "\(locale): \(word)")
            }
        }
    }

    // MARK: - Helpers

    /// `WatchAppState.refreshAll`'s use of the hold, on the client alone.
    private static func watchRefresh(_ api: APIClient, hold: inout Hold, now: Date) async {
        let held = await api.getToken()
        if WatchCredentialRelay.hasExpired(held, now: now), !hold.covers(held) { hold.refused(held, at: now) }
        if hold.holdsBack(held, now: now) {
            _ = try? await api.refreshAccessToken()
            if hold.holdsBack(await api.getToken(), now: now) { return }
        }
        let sent = await api.getToken()
        do {
            _ = try await api.alerts()
            hold.clear()
        } catch {
            if (error as? WatchCredentialRelayError) == .waitingForPhone { hold.refused(sent, at: now) }
        }
    }

    private static func jwt(sub: String, expiresIn seconds: TimeInterval) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"sub\":\"\(sub)\",\"exp\":\(exp)}")).signature"
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

/// The iPhone as the Watch's renewer sees it: no answer while locked, then
/// the token it gives once unlocked. Counts the questions.
private final class PhoneStub: @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var questions = 0

    var asked: Int { lock.lock(); defer { lock.unlock() }; return questions }

    func give(_ token: String) { lock.lock(); self.token = token; lock.unlock() }

    func answer() throws -> String {
        lock.lock(); defer { lock.unlock() }
        questions += 1
        guard let token else { throw WatchCredentialRelayError.waitingForPhone }
        return token
    }
}
