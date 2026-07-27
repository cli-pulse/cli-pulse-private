import Foundation

/// Immutable proof that a watch refresh still belongs to the current
/// authenticated session and is the newest refresh started in that session.
public struct WatchRefreshLease: Equatable, Sendable {
    fileprivate let authGeneration: UInt64
    fileprivate let refreshGeneration: UInt64
}

/// Small value-state gate used by WatchAppState to prevent an async response
/// from user A (or an older overlapping request) committing after sign-out or
/// an account switch.
public struct WatchRefreshGate: Sendable {
    private var authGeneration: UInt64 = 0
    private var refreshGeneration: UInt64 = 0

    public init() {}

    /// Invalidate every lease from the previous auth boundary.
    public mutating func authDidChange() {
        authGeneration &+= 1
        refreshGeneration = 0
    }

    /// Start a newest-wins refresh for the current authenticated session.
    public mutating func beginRefresh(
        isAuthenticated: Bool
    ) -> WatchRefreshLease? {
        guard isAuthenticated else { return nil }
        refreshGeneration &+= 1
        return WatchRefreshLease(
            authGeneration: authGeneration,
            refreshGeneration: refreshGeneration
        )
    }

    public func canCommit(
        _ lease: WatchRefreshLease,
        isAuthenticated: Bool
    ) -> Bool {
        isAuthenticated
            && lease.authGeneration == authGeneration
            && lease.refreshGeneration == refreshGeneration
    }
}
