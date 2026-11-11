// 1.63 (A1): the Watch's Sign Out, through the two steps `WatchAppState.signOut`
// hands it to (`WatchSignOut.captureAndClear`, then `WatchSignOut.finish`).
//
// The Watch clears its Keychain, and its client lets go of the session, before
// the revoke runs. So a session the Watch signed in to on its own must be read,
// both tokens, before anything is deleted, and revoked with that pair; and a
// session relayed from the iPhone must send nothing at all (the iPhone's Sign
// Out ends it). The store here is a dictionary that records every read and
// delete; the client is the real one over `SessionRestoreStub`.

import Foundation
import XCTest
@testable import CLIPulseCore

@MainActor
final class WatchSignOutTests: XCTestCase {

    private static let userID = "00000000-0000-0000-0000-0000000000a1"
    private static let tokenPath = "/auth/v1/token"
    private static let logoutPath = "/auth/v1/logout"

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

    /// Signed in on the Watch with a code: its own session, revoked from here
    /// with its own pair, read before the deletes.
    func test_a_session_signed_in_on_the_Watch_is_revoked_with_its_own_pair() async {
        SessionRestoreStub.respond { request in
            request.url?.path == Self.logoutPath ? .status(204, "") : .status(500)
        }
        let store = Store([
            WatchSignOut.accessTokenKey: "watch-access",
            WatchSignOut.refreshTokenKey: "watch-refresh",
            WatchSessionRecord.keychainKey: WatchSessionRecord(source: .watch, userID: Self.userID).encoded,
        ])
        let (api, auth) = await Self.watchClient(access: "watch-access", refresh: "watch-refresh")

        let revocation = WatchSignOut.captureAndClear(store.credentials, lastPhoneUserID: nil, currentSource: .watch)

        XCTAssertEqual(revocation, .own(RevocationSnapshot(accessToken: "watch-access", refreshToken: "watch-refresh")))
        XCTAssertTrue(store.items.isEmpty, "the stored session is deleted")
        XCTAssertTrue(store.readsComeBeforeDeletes, "everything is read before anything is deleted: \(store.events)")
        XCTAssertTrue(SessionRestoreStub.requests().isEmpty, "nothing sent until the hand-off")

        await WatchSignOut.finish(revocation, transitionGeneration: 2, api: api, authManager: auth)

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.logoutPath])
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["watch-access"])
        SessionRestoreStub.assertEveryLogoutIsLocal()
        let held = await api.getToken()
        XCTAssertNil(held, "the client let go of the session")
    }

    /// The same session with an expired access token. The client holds nothing
    /// by the time the revoke runs, so only the pair read here can refresh it:
    /// the refresh goes out with the Watch's own refresh token, and nothing
    /// it brings back is installed.
    func test_an_expired_Watch_session_is_refreshed_with_the_pair_read_before_the_deletes() async {
        let expired = Self.jwt(expiresIn: -3_600)
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case Self.tokenPath: return .status(200, #"{"access_token":"watch-access-2","refresh_token":"watch-refresh-2"}"#)
            case Self.logoutPath: return .status(204, "")
            default: return .status(500)
            }
        }
        let store = Store([
            WatchSignOut.accessTokenKey: expired,
            WatchSignOut.refreshTokenKey: "watch-refresh",
            WatchSessionRecord.keychainKey: WatchSessionRecord(source: .watch, userID: Self.userID).encoded,
        ])
        let (api, auth) = await Self.watchClient(access: expired, refresh: "watch-refresh")

        let revocation = WatchSignOut.captureAndClear(store.credentials, lastPhoneUserID: nil, currentSource: .watch)
        await WatchSignOut.finish(revocation, transitionGeneration: 2, api: api, authManager: auth)

        XCTAssertEqual(SessionRestoreStub.paths(), [Self.tokenPath, Self.logoutPath])
        XCTAssertEqual(SessionRestoreStub.refreshTokensSent(), ["watch-refresh"])
        XCTAssertEqual(SessionRestoreStub.authorizations(Self.logoutPath), ["watch-access-2"])
        SessionRestoreStub.assertEveryLogoutIsLocal()
        let held = await api.getToken()
        XCTAssertNil(held, "the revoke's refresh installs nothing")
        XCTAssertNil(KeychainHelper.load(key: WatchSignOut.accessTokenKey), "nor writes anything")
    }

    /// A session from the iPhone is the iPhone's: no request at all.
    func test_a_session_relayed_from_the_iPhone_sends_nothing() async {
        SessionRestoreStub.respond { _ in .status(204, "") }
        let store = Store([
            WatchSignOut.accessTokenKey: "phone-access",
            WatchSessionRecord.keychainKey: WatchSessionRecord(source: .phone, userID: Self.userID).encoded,
        ])
        let (api, auth) = await Self.watchClient(access: "phone-access", refresh: nil, relayed: true)

        let revocation = WatchSignOut.captureAndClear(store.credentials, lastPhoneUserID: Self.userID, currentSource: .phone)
        await WatchSignOut.finish(revocation, transitionGeneration: 2, api: api, authManager: auth)

        XCTAssertEqual(revocation, .relayed)
        XCTAssertTrue(store.items.isEmpty, "the stored session is deleted all the same")
        XCTAssertTrue(SessionRestoreStub.requests().isEmpty, "a relayed session makes zero requests")
        let held = await api.getToken()
        XCTAssertNil(held)
    }

    /// A session stored before 1.61 has no record. As a restore reads it, one
    /// whose token is the iPhone's account is the iPhone's, even with a
    /// refresh token kept next to it, so it is not revoked from here.
    func test_an_unrecorded_session_of_the_iPhones_account_is_not_revoked_from_the_Watch() async {
        SessionRestoreStub.respond { _ in .status(204, "") }
        let token = Self.jwt(expiresIn: 600)
        let store = Store([
            WatchSignOut.accessTokenKey: token,
            WatchSignOut.refreshTokenKey: "kept-refresh",
        ])
        let (api, auth) = await Self.watchClient(access: token, refresh: "kept-refresh")

        let revocation = WatchSignOut.captureAndClear(store.credentials, lastPhoneUserID: Self.userID, currentSource: .watch)
        await WatchSignOut.finish(revocation, transitionGeneration: 2, api: api, authManager: auth)

        XCTAssertEqual(revocation, .relayed)
        XCTAssertTrue(SessionRestoreStub.requests().isEmpty)
    }

    func test_nothing_stored_sends_nothing() async {
        SessionRestoreStub.respond { _ in .status(204, "") }
        let store = Store([:])
        let (api, auth) = await Self.watchClient(access: nil, refresh: nil)

        let revocation = WatchSignOut.captureAndClear(store.credentials, lastPhoneUserID: nil, currentSource: .watch)
        await WatchSignOut.finish(revocation, transitionGeneration: 2, api: api, authManager: auth)

        XCTAssertEqual(revocation, .nothing)
        XCTAssertTrue(SessionRestoreStub.requests().isEmpty)
    }

    // MARK: - Helpers

    /// The Watch's Keychain items, recording each read and delete in order.
    final class Store {
        private(set) var items: [String: String]
        private(set) var events: [String] = []

        init(_ items: [String: String]) { self.items = items }

        var credentials: WatchSignOut.CredentialStore {
            WatchSignOut.CredentialStore(
                load: { key in
                    self.events.append("load \(key)")
                    return self.items[key]
                },
                delete: { key in
                    self.events.append("delete \(key)")
                    self.items[key] = nil
                }
            )
        }

        var readsComeBeforeDeletes: Bool {
            guard
                let lastRead = events.lastIndex(where: { $0.hasPrefix("load ") }),
                let firstDelete = events.firstIndex(where: { $0.hasPrefix("delete ") })
            else { return false }
            return lastRead < firstDelete
        }
    }

    /// The Watch's client and auth manager as `WatchAppState` builds them, with
    /// the session installed by an earlier transition (generation 1). The
    /// tokens the auth manager writes go to the in-memory Keychain.
    private static func watchClient(
        access: String?, refresh: String?, relayed: Bool = false
    ) async -> (APIClient, AuthManager) {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        _ = await api.beginExternalAuthorizationTransition(generation: 1)
        var renewer: APIClient.SessionRenewer?
        if relayed { renewer = { "unused" } }
        if let access {
            _ = await api.installExternalAuthenticatedSession(
                accessToken: access, refreshToken: refresh, userID: userID, transitionGeneration: 1,
                renewer: renewer
            )
        }
        let auth = AuthManager(api: api) { access, refresh in
            if access.isEmpty {
                KeychainHelper.delete(key: WatchSignOut.accessTokenKey)
            } else {
                KeychainHelper.save(key: WatchSignOut.accessTokenKey, value: access)
            }
            if let refresh, !refresh.isEmpty {
                KeychainHelper.save(key: WatchSignOut.refreshTokenKey, value: refresh)
            } else {
                KeychainHelper.delete(key: WatchSignOut.refreshTokenKey)
            }
        }
        return (api, auth)
    }

    /// An unsigned, made-up JWT for `userID` whose `exp` is `seconds` from now.
    private static func jwt(expiresIn seconds: TimeInterval) -> String {
        func b64(_ json: String) -> String {
            Data(json.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }
        let exp = Int(Date().addingTimeInterval(seconds).timeIntervalSince1970)
        return "\(b64(#"{"alg":"ES256","typ":"JWT"}"#)).\(b64("{\"sub\":\"\(userID)\",\"exp\":\(exp)}")).signature"
    }
}
