import Foundation

/// Opaque proof that an asynchronous watch authentication operation is still
/// the newest transition requested by the UI.
public struct WatchAuthTransitionLease: Equatable, Sendable {
    public let generation: UInt64

    fileprivate init(generation: UInt64) {
        self.generation = generation
    }
}

/// Credential side-effect policy for watch authentication boundaries. Demo
/// mode must invalidate live API work without deleting the real session that
/// the user expects to resume after leaving the demo.
public enum WatchAuthTransitionKind: Sendable {
    case authentication
    case sessionRestore
    case demoMode

    public var clearsPersistedCredentials: Bool {
        self == .authentication
    }
}

/// A restore failure is not proof that the durable session is invalid.
/// Transient transport/server failures preserve Keychain so the next launch
/// can retry. Only an explicit authentication rejection clears it.
public enum WatchSessionRestoreCredentialPolicy {
    public static func shouldDeletePersistedCredentials(
        after error: APIError
    ) -> Bool {
        switch error {
        case .tokenExpired:
            return true
        case let .httpError(status, _):
            return status == 401
        case .invalidResponse:
            return false
        }
    }
}

/// Newest-wins gate for OTP verification, session restore, phone auth, and
/// logout. Data refreshes use `WatchRefreshGate`; authentication needs a
/// separate boundary because it also owns Keychain and API session changes.
public struct WatchAuthTransitionGate: Sendable {
    private var generation: UInt64 = 0

    public init() {}

    public mutating func beginTransition()
        -> WatchAuthTransitionLease {
        generation &+= 1
        return WatchAuthTransitionLease(
            generation: generation
        )
    }

    public func canCommit(
        _ lease: WatchAuthTransitionLease
    ) -> Bool {
        lease.generation == generation
    }
}

/// Owner and monotonic epoch attached to every iPhone-to-Watch auth, logout,
/// and fallback snapshot. The user ID is normalized only for comparison and
/// never derived from labels or email addresses.
public struct WatchSessionIdentity: Equatable, Sendable {
    public let userID: String
    public let epoch: UInt64

    public init?(userID: String, epoch: UInt64) {
        let normalized = userID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty, epoch > 0 else {
            return nil
        }
        self.userID = normalized
        self.epoch = epoch
    }

    public func matches(
        authenticatedUserID: String,
        remoteEpoch: UInt64?
    ) -> Bool {
        let normalized = authenticatedUserID
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized == userID else { return false }
        guard let remoteEpoch else { return true }
        return remoteEpoch == epoch
    }
}

/// Rejects delayed WatchConnectivity messages from an older phone auth
/// session while allowing auth and context messages that share one epoch.
public struct WatchSessionOrderingGate: Sendable {
    public private(set) var highestAcceptedEpoch: UInt64
    public private(set) var highestAcceptedUserID: String?

    public init(
        highestAcceptedEpoch: UInt64 = 0,
        highestAcceptedUserID: String? = nil
    ) {
        self.highestAcceptedEpoch = highestAcceptedEpoch
        self.highestAcceptedUserID =
            highestAcceptedUserID.flatMap {
                WatchSessionIdentity(
                    userID: $0,
                    epoch: max(highestAcceptedEpoch, 1)
                )?.userID
            }
    }

    public mutating func accept(
        _ identity: WatchSessionIdentity
    ) -> Bool {
        guard identity.epoch >= highestAcceptedEpoch else {
            return false
        }
        if identity.epoch == highestAcceptedEpoch,
           let highestAcceptedUserID,
           highestAcceptedUserID != identity.userID {
            return false
        }
        highestAcceptedEpoch = identity.epoch
        highestAcceptedUserID = identity.userID
        return true
    }
}

/// Decides whether a newest accepted phone logout must invalidate the watch
/// authentication state. During OTP/restore/phone-auth transitions the UI is
/// intentionally marked signed out and the final user ID may not be known yet;
/// a remote logout must still cancel that pending transition. Once a session
/// is authenticated, owner and epoch checks prevent another account's delayed
/// logout from clearing it.
public enum WatchRemoteLogoutPolicy {
    public static func shouldInvalidateAuthentication(
        isAuthenticated: Bool,
        currentUserID: String,
        currentRemoteEpoch: UInt64?,
        logoutIdentity: WatchSessionIdentity
    ) -> Bool {
        guard isAuthenticated else {
            return true
        }
        guard
            let currentIdentity = WatchSessionIdentity(
                userID: currentUserID,
                epoch: 1
            ),
            currentIdentity.userID
                == logoutIdentity.userID
        else {
            return false
        }
        if let currentRemoteEpoch,
           logoutIdentity.epoch < currentRemoteEpoch {
            return false
        }
        return true
    }
}

/// Coalesces the two delivery copies of one phone logout. iPhone sends both a
/// queued user-info message and an application-context tombstone so at least
/// one survives background delivery. They carry the same identity and must be
/// treated as one event; otherwise the delayed copy can sign out a newer local
/// Watch login that completed after the first copy was handled.
public struct WatchLogoutDeduplicationGate: Sendable {
    public private(set) var lastAcceptedIdentity:
        WatchSessionIdentity?

    public init(
        lastAcceptedIdentity: WatchSessionIdentity? = nil
    ) {
        self.lastAcceptedIdentity = lastAcceptedIdentity
    }

    public mutating func accept(
        _ identity: WatchSessionIdentity
    ) -> Bool {
        guard identity != lastAcceptedIdentity else {
            return false
        }
        lastAcceptedIdentity = identity
        return true
    }
}
