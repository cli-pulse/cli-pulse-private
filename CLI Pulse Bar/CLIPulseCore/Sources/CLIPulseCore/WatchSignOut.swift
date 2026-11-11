import Foundation
import os

private let watchSignOutLogger = Logger(subsystem: "com.clipulse", category: "WatchSignOut")

// MARK: - 1.63 (A1): the Watch's Sign Out, from its stored session to the server
//
// The Watch clears its Keychain, and its API client lets go of the session
// (`APIClient.beginExternalAuthorizationTransition`), before the sign-out's
// revoke runs, so the client holds nothing by then. A session the Watch signed
// in to on its own (a code sent by email) is revoked with the pair read here,
// before anything was deleted. A session the iPhone relayed is the iPhone's:
// the iPhone's Sign Out ends it, and the Watch sends nothing for it.
//
// `WatchAppState.signOut` (the Watch target, which no test target builds)
// calls these two steps; the tests drive them with an in-memory store and a
// stubbed client.

/// What a Watch sign-out does with its session on the server.
public enum WatchSignOutRevocation: Equatable, Sendable {
    /// Signed in on the Watch: revoked from here, with its own pair.
    case own(RevocationSnapshot)
    /// The iPhone's session, relayed to the Watch: not revoked here.
    case relayed
    /// Nothing stored that a revoke could use.
    case nothing
}

public enum WatchSignOut {
    public static let accessTokenKey = "cli_pulse_token"
    public static let refreshTokenKey = "cli_pulse_refresh_token"

    /// The Watch's stored credentials: its Keychain in the app, a dictionary
    /// in the tests.
    public struct CredentialStore {
        public let load: (String) -> String?
        public let delete: (String) -> Void

        public init(load: @escaping (String) -> String?, delete: @escaping (String) -> Void) {
            self.load = load
            self.delete = delete
        }

        public static var keychain: CredentialStore {
            CredentialStore(
                load: { KeychainHelper.load(key: $0) },
                delete: { _ = KeychainHelper.delete(key: $0) }
            )
        }
    }

    /// Reads the stored session and decides what the server is told, THEN
    /// deletes the stored credentials, so the pair is the one the Watch held.
    ///
    /// Whose session it is is resolved as a restore resolves it
    /// (`WatchSessionRecord.resolve`): the stored record first (a restore or a
    /// sign-in still in flight has already reset `currentSource`), so a
    /// session stored before 1.61 that is the iPhone's is not revoked from
    /// here either.
    public static func captureAndClear(
        _ store: CredentialStore,
        lastPhoneUserID: String?,
        currentSource: WatchSessionSource
    ) -> WatchSignOutRevocation {
        let token = store.load(accessTokenKey) ?? ""
        let refreshToken = store.load(refreshTokenKey) ?? ""
        let revokesOnServer = (
            WatchSessionRecord.resolve(
                stored: store.load(WatchSessionRecord.keychainKey),
                accessToken: token,
                lastPhoneUserID: lastPhoneUserID,
                hasRefreshToken: !refreshToken.isEmpty
            )?.source ?? currentSource
        ).renewsItself
        store.delete(accessTokenKey)
        store.delete(refreshTokenKey)
        store.delete(WatchSessionRecord.keychainKey)
        guard revokesOnServer else { return .relayed }
        guard !token.isEmpty else { return .nothing }
        return .own(RevocationSnapshot(accessToken: token, refreshToken: refreshToken))
    }

    /// The rest of the sign-out, after the Watch shows signed out: the client
    /// lets go of the session (a newest-wins transition: a sign-in started
    /// since is not undone), then the Watch's own session is revoked with the
    /// pair `captureAndClear` read.
    @MainActor
    public static func finish(
        _ revocation: WatchSignOutRevocation,
        transitionGeneration: UInt64,
        api: APIClient,
        authManager: AuthManager
    ) async {
        _ = await api.beginExternalAuthorizationTransition(generation: transitionGeneration)
        switch revocation {
        case .own(let snapshot):
            await authManager.signOut(fence: nil, snapshot: snapshot)
        case .relayed:
            watchSignOutLogger.info("relayed session: not revoked here")
        case .nothing:
            break
        }
    }
}
