import Foundation
import os

private let watchSignOutLogger = Logger(subsystem: "com.clipulse", category: "WatchSignOut")

// MARK: - 1.63 (A1): the Watch's Sign Out, from its stored session to the server
//
// The Watch clears its Keychain, and its API client lets go of the session
// (`APIClient.beginExternalAuthorizationTransition`), before the sign-out's
// revoke runs. Every Watch sign-out is fenced first, as the app's are, before
// anything is read or deleted: a refresh that comes back after that writes
// nothing and keeps its new pair for the revocation. A session the Watch
// signed in to on its own (a code sent by email) has its revocation bound to
// it (`APIClient.beginRevocation`) before the client lets go: the client's
// newest pair if it still holds the session, else the pair read here, and a
// refresh of it still out is waited for and its new pair used. A session the
// iPhone relayed is the iPhone's: the iPhone's Sign Out ends it, the Watch
// sends nothing for it, and its fence is released at once.
//
// `WatchAppState.signOut` (the Watch target, which no test target builds)
// calls these two steps; the tests drive them with an in-memory store and a
// stubbed client.

/// What a Watch sign-out does with its session on the server. `fence`: what
/// `APIClient.fenceCurrentSession()` returned for this sign-out.
public enum WatchSignOutRevocation: Equatable, Sendable {
    /// Signed in on the Watch: revoked from here, with its own pair.
    case own(RevocationSnapshot, fence: UInt64)
    /// The iPhone's session, relayed to the Watch: not revoked here.
    case relayed(fence: UInt64)
    /// Nothing stored that a revoke could use.
    case nothing(fence: UInt64)
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

    /// Fences the sign-out (`fence`, called once, first), THEN reads the
    /// stored session and decides what the server is told, THEN deletes the
    /// stored credentials. After the fence no refresh writes the stored pair
    /// (`APIClient` writes under the fence's lock), so the pair read is the
    /// last one written, and nothing is written back after the deletes.
    ///
    /// Whose session it is is resolved as a restore resolves it
    /// (`WatchSessionRecord.resolve`): the stored record first (a restore or a
    /// sign-in still in flight has already reset `currentSource`), so a
    /// session stored before 1.61 that is the iPhone's is not revoked from
    /// here either.
    public static func captureAndClear(
        _ store: CredentialStore,
        lastPhoneUserID: String?,
        currentSource: WatchSessionSource,
        fence: () -> UInt64
    ) -> WatchSignOutRevocation {
        let fenceValue = fence()
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
        guard revokesOnServer else { return .relayed(fence: fenceValue) }
        guard !token.isEmpty else { return .nothing(fence: fenceValue) }
        return .own(RevocationSnapshot(accessToken: token, refreshToken: refreshToken), fence: fenceValue)
    }

    /// The rest of the sign-out, after the Watch shows signed out. The Watch's
    /// own session: its revocation is bound to it first, then the client lets
    /// go (a newest-wins transition: a sign-in started since is not undone),
    /// then it is revoked. Any other: the client lets go, and nothing is sent.
    @MainActor
    public static func finish(
        _ revocation: WatchSignOutRevocation,
        transitionGeneration: UInt64,
        api: APIClient,
        authManager: AuthManager
    ) async {
        switch revocation {
        case .own(let snapshot, let fence):
            let bound = await api.beginRevocation(fence: fence, snapshot: snapshot)
            _ = await api.beginExternalAuthorizationTransition(generation: transitionGeneration)
            await authManager.finishSignOut(bound)
        case .relayed(let fence):
            _ = await api.beginExternalAuthorizationTransition(generation: transitionGeneration)
            api.releaseFence(fence)
            watchSignOutLogger.info("relayed session: not revoked here")
        case .nothing(let fence):
            _ = await api.beginExternalAuthorizationTransition(generation: transitionGeneration)
            api.releaseFence(fence)
        }
    }
}
