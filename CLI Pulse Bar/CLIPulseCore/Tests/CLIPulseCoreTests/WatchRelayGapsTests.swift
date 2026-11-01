// 1.61: the gaps the independent review of #732 found in how the Watch and
// the iPhone pass the session's access token.
//
// - A token delivered while the Watch app launches was dropped (should-fix 2).
// - An iPhone asked by a Watch holding the iPhone's current token handed the
//   same token back, a loop when the server had refused it (minor).
// - A question queued before an auth transition could be answered into the
//   next session (minor).
// - "No answer now" left nothing queued (minor), and a Watch launched out of
//   the iPhone's reach asked nothing until its next tick (minor).
// The decisions are pure functions here; the app targets have no test target,
// so their wiring is pinned by reading the source.

import Foundation
import XCTest
@testable import CLIPulseCore

final class WatchRelayGapsTests: XCTestCase {

    private static let userA = "00000000-0000-0000-0000-00000000000a"
    private static let userB = "00000000-0000-0000-0000-00000000000b"

    // MARK: - "My token is this one"

    func test_a_request_carries_the_held_tokens_fingerprint_never_the_token() {
        let token = Self.jwt(sub: Self.userA, expiresIn: 3_600)
        let request = WatchCredentialRelay.request(userID: Self.userA, heldToken: token)

        XCTAssertEqual(WatchCredentialRelay.requestedUserID(in: request), Self.userA)
        XCTAssertEqual(WatchCredentialRelay.heldTokenFingerprint(in: request), WatchCredentialRelay.fingerprint(token))
        XCTAssertFalse(request.values.contains { ($0 as? String) == token }, "the token itself never goes back")
        XCTAssertNil(WatchCredentialRelay.heldTokenFingerprint(in: WatchCredentialRelay.request(userID: Self.userA)))
        XCTAssertNil(WatchCredentialRelay.heldTokenFingerprint(in: ["held_token_fingerprint": "x"]), "not a request")
        XCTAssertEqual(WatchCredentialRelay.fingerprint(token), WatchCredentialRelay.fingerprint(token))
        XCTAssertNotEqual(WatchCredentialRelay.fingerprint(token), WatchCredentialRelay.fingerprint(token + "x"))
        XCTAssertEqual(WatchCredentialRelay.fingerprint(token).count, 32)
    }

    /// The iPhone's token is still valid, but the Watch already holds it and
    /// asked anyway (the server refused it): refresh, or no answer if locked.
    func test_an_iphone_asked_for_the_token_the_watch_holds_refreshes_it() {
        let fresh = Self.jwt(sub: Self.userA, expiresIn: 3_600)
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: fresh, canPersist: true, watchHoldsIt: true), .renewFirst)
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: fresh, canPersist: false, watchHoldsIt: true), .noAnswer,
                       "locked: never hand back the refused token, never refresh")
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: fresh, canPersist: true), .sendAsIs,
                       "control: a Watch holding another token gets this one")
    }

    /// Several of the Watch's requests went out with the old token; the first
    /// question got the new one. The later questions, holding the new one,
    /// must not each rotate it again.
    func test_a_token_refreshed_just_now_is_not_refreshed_again_for_the_watch() {
        let fresh = Self.jwt(sub: Self.userA, expiresIn: 3_600)
        let now = Date()
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: fresh, now: now, canPersist: true,
                                                         watchHoldsIt: true, refreshedAt: now.addingTimeInterval(-10)),
                       .sendAsIs)
        XCTAssertEqual(WatchCredentialRelay.phoneRenewal(accessToken: fresh, now: now, canPersist: true,
                                                         watchHoldsIt: true, refreshedAt: now.addingTimeInterval(-120)),
                       .renewFirst)
    }

    // MARK: - A token delivered before the session is in

    func test_the_newest_delivered_token_is_kept_and_only_for_its_account() {
        let older = Self.jwt(sub: Self.userA, expiresIn: 1_000)
        let newer = Self.jwt(sub: Self.userA, expiresIn: 3_000)
        let foreign = Self.jwt(sub: Self.userB, expiresIn: 9_000)

        XCTAssertEqual(WatchCredentialRelay.newerDelivered(older, than: nil, userID: Self.userA), older)
        XCTAssertEqual(WatchCredentialRelay.newerDelivered(newer, than: older, userID: Self.userA), newer)
        XCTAssertEqual(WatchCredentialRelay.newerDelivered(older, than: newer, userID: Self.userA), newer,
                       "a transfer that arrives late does not replace a newer token")
        XCTAssertEqual(WatchCredentialRelay.newerDelivered(foreign, than: older, userID: Self.userA), older,
                       "another account's token is never kept")
        XCTAssertNil(WatchCredentialRelay.newerDelivered(foreign, than: nil, userID: Self.userA))
    }

    func test_the_delivered_token_keeper() {
        let older = Self.jwt(sub: Self.userA, expiresIn: 1_000)
        let newer = Self.jwt(sub: Self.userA, expiresIn: 3_000)
        let foreign = Self.jwt(sub: Self.userB, expiresIn: 9_000)
        var kept = WatchCredentialRelay.DeliveredToken()

        kept.offer(newer, userID: Self.userA)
        kept.offer(older, userID: Self.userA)
        XCTAssertEqual(kept.token(for: Self.userA), newer, "a late transfer does not replace a newer token")
        kept.offer(foreign, userID: Self.userA)
        XCTAssertEqual(kept.token(for: Self.userA), newer, "a token whose sub is another account is refused")
        XCTAssertNil(kept.token(for: Self.userB))
        kept.offer(foreign, userID: Self.userB)
        XCTAssertEqual(kept.token(for: Self.userB), foreign, "another account's own token replaces it")
        XCTAssertNil(kept.token(for: Self.userA))
        kept.clear()
        XCTAssertNil(kept.token(for: Self.userB))
    }

    func test_a_kept_token_is_used_instead_of_asking_only_when_it_can_work() {
        let valid = Self.jwt(sub: Self.userA, expiresIn: 3_000)
        XCTAssertEqual(WatchCredentialRelay.usableDelivered(valid, userID: Self.userA, holding: "other"), valid)
        XCTAssertNil(WatchCredentialRelay.usableDelivered(valid, userID: Self.userA, holding: valid),
                     "the token held is the one being renewed")
        XCTAssertNil(WatchCredentialRelay.usableDelivered(Self.jwt(sub: Self.userA, expiresIn: 30), userID: Self.userA, holding: nil),
                     "about to expire")
        XCTAssertNil(WatchCredentialRelay.usableDelivered(Self.jwt(sub: Self.userA, expiresIn: -10), userID: Self.userA, holding: nil))
        XCTAssertNil(WatchCredentialRelay.usableDelivered(Self.jwt(sub: Self.userB, expiresIn: 3_000), userID: Self.userA, holding: nil))
        XCTAssertNil(WatchCredentialRelay.usableDelivered(nil, userID: Self.userA, holding: nil))
    }

    // MARK: - The wiring (app targets have no tests)

    func test_the_watch_keeps_a_token_delivered_while_restoring_and_adopts_it_after() throws {
        let watch = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let adopt = try Self.section(watch, from: "private func adoptPhoneAccessToken(", to: "guard\n            isAuthenticated,")
        XCTAssertNotNil(adopt.range(of: #"if !isAuthenticated \{\s*deliveredPhoneToken\.offer\(token, userID: identity\.userID\)\s*return"#,
                                    options: .regularExpression))

        let restore = try Self.section(watch, from: "let response = try await candidateAPI.me()", to: "} catch {")
        XCTAssertNotNil(restore.range(of: #"await adoptDeliveredPhoneToken\(\)\s*await refreshAll\(\)"#, options: .regularExpression))
        let offline = try Self.section(watch, from: "private func commitPhoneSessionOffline(", to: "// MARK: - WCSession Fallback")
        XCTAssertTrue(offline.contains("if await adoptDeliveredPhoneToken() {"))

        let renew = try Self.section(watch, from: "private func renewFromPhone(", to: "switch WatchCredentialRelay.watchAction(")
        let usable = try XCTUnwrap(renew.range(of: "WatchCredentialRelay.usableDelivered("))
        let ask = try XCTUnwrap(renew.range(of: "requestCurrentCredentials(userID: userID, heldToken: held)"))
        XCTAssertLessThan(usable.lowerBound, ask.lowerBound, "a kept token is tried before asking")

        let signOut = try Self.section(watch, from: "func signOut() {", to: "let revokesOnServer")
        XCTAssertTrue(signOut.contains("deliveredPhoneToken.clear()"))
    }

    func test_queued_questions_are_cancelled_on_every_auth_transition() throws {
        let watch = try Self.code("CLI Pulse Bar Watch/WatchAppState.swift")
        let signOut = try Self.section(watch, from: "func signOut() {", to: "let revokesOnServer")
        XCTAssertTrue(signOut.contains("WatchSessionManager.shared.cancelQueuedCredentialRequests()"))
        let transition = try Self.section(watch, from: "private func beginAuthTransition(", to: "let began = await api")
        XCTAssertTrue(transition.contains("WatchSessionManager.shared.cancelQueuedCredentialRequests()"))

        let manager = try Self.code("CLI Pulse Bar Watch/WatchSessionManager.swift")
        let cancel = try Self.section(manager, from: "func cancelQueuedCredentialRequests()", to: "\n    }\n")
        XCTAssertTrue(cancel.contains("WatchCredentialRelay.requestedUserID(in: transfer.userInfo) != nil"))
        XCTAssertTrue(cancel.contains("transfer.cancel()"))
    }

    func test_no_answer_now_still_leaves_the_question_queued() throws {
        let manager = try Self.code("CLI Pulse Bar Watch/WatchSessionManager.swift")
        let request = try Self.section(manager, from: "func requestCurrentCredentials(", to: "func cancelQueuedCredentialRequests()")
        XCTAssertTrue(request.contains("if let reply, reply != .unavailable { return reply }"))
        XCTAssertTrue(request.contains("WatchCredentialRelay.request(userID: userID, heldToken: heldToken)"))
        let activation = try Self.section(manager, from: "activationDidCompleteWith activationState", to: "// Load any previously persisted data")
        XCTAssertTrue(activation.contains("NotificationCenter.default.post(name: .watchPhoneBecameReachable"))
        XCTAssertFalse(activation.contains("if session.isReachable {"), "asked on activation, reachable or not")
    }

    func test_the_iphone_refreshes_a_token_the_watch_already_holds() throws {
        let phone = try Self.code("CLI Pulse Bar iOS/PhoneSessionManager.swift")
        let answer = try Self.section(phone, from: "func credentialAnswer(", to: "private func currentIdentity()")
        XCTAssertTrue(answer.contains("watchHoldsIt: heldFingerprint == WatchCredentialRelay.fingerprint(token)"))
        XCTAssertTrue(answer.contains("return lastRotationAt"), "a token refreshed just now is not refreshed again")
        let rotation = try Self.section(phone, from: "func handleDidRotateAccessToken(", to: "sendCredentialsToWatch(")
        XCTAssertTrue(rotation.contains("lastRotationAt = Date()"))
        let handlers = try Self.section(phone, from: "extension PhoneSessionManager: WCSessionDelegate", to: "private struct SendableReply")
        XCTAssertEqual(handlers.components(separatedBy: "heldFingerprint: held)").count - 1, 2, "both handlers pass it on")
    }

    // MARK: - Helpers

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
