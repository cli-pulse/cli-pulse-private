import Foundation
#if os(iOS)
import UIKit
#endif

/// 1.61: the signed-in session's tokens on their way to the Keychain, and
/// held in memory when the Keychain would not take them.
///
/// The iPhone keeps them `WhenUnlockedThisDeviceOnly`. Since the Watch asks the
/// iPhone for each new token (#732), its `sendMessage` wakes or launches the
/// iPhone app in the background, often while the iPhone is locked. A refresh
/// that finishes then has already spent the old refresh token on the server,
/// and the new pair cannot be written: `persistAuthTokens` ignored that, so
/// the Keychain kept the spent token, and the next cold launch presented it,
/// was refused, and signed the user out.
///
/// Now a pair that could not be written is kept here, every read of the
/// stored tokens returns it instead of the Keychain's older one, and the
/// write is tried again (`retryUnsaved()`): when protected data comes back,
/// when the app comes to the front, and before each refresh.
final class SessionTokenStore: @unchecked Sendable {
    struct Pair: Equatable {
        let access: String
        let refresh: String?
    }

    static let shared = SessionTokenStore(
        defaults: .standard,
        tracksUnsavedPairs: SessionTokenStore.isIPhone,
        writer: SessionTokenStore.write
    )

    #if os(iOS)
    static let isIPhone = true
    #else
    static let isIPhone = false
    #endif

    /// 1.62: set while a non-empty pair is held unwritten, so the next launch
    /// can tell the previous run ended holding one (`pending_at_launch`). A
    /// flag only: no token, no time. iPhone only; the Mac's Keychain does not
    /// lock under the app.
    static let unsavedMarkerKey = "cli_pulse_session_pair_unsaved"

    private let lock = NSLock()
    private var unsaved: Pair?
    private let defaults: UserDefaults
    private let tracksUnsavedPairs: Bool
    private let writer: (Pair) -> Bool
    private var launchMarkerConsumed = false

    /// 1.62: each hold, late write and leftover from the previous run
    /// (`KeychainReports.installForIPhone`). Called outside the lock.
    var onEvent: (@Sendable (KeychainReport.SessionPairOutcome) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return eventHandler }
        set { lock.lock(); eventHandler = newValue; lock.unlock() }
    }
    private var eventHandler: (@Sendable (KeychainReport.SessionPairOutcome) -> Void)?
    /// Events leave in the order their transitions happened: queued here while
    /// the lock is held, delivered outside it.
    private let eventQueue = DispatchQueue(label: "cli-pulse.session-pair-events")

    init(defaults: UserDefaults, tracksUnsavedPairs: Bool, writer: @escaping (Pair) -> Bool) {
        self.defaults = defaults
        self.tracksUnsavedPairs = tracksUnsavedPairs
        self.writer = writer
    }

    /// Write `pair`; keep it in memory if any part of the write failed.
    /// Writes are serialized, so an older pair never lands after a newer one.
    @discardableResult
    func persist(_ pair: Pair) -> Bool {
        lock.lock()
        var events = consumeLaunchMarkerLocked()
        let wasHoldingCredentials = unsaved.map { !$0.access.isEmpty } ?? false
        let wrote = writer(pair)
        if wrote {
            unsaved = nil
            setMarkerLocked(false)
        } else {
            unsaved = pair
            if pair.access.isEmpty {
                // A sign-out: whatever the Keychain kept, the user meant to
                // leave, so a later launch has nothing to report.
                setMarkerLocked(false)
            } else {
                setMarkerLocked(true)
                if !wasHoldingCredentials { events.append(.held) }
            }
        }
        deliverLocked(events)
        lock.unlock()
        return wrote
    }

    /// Write the pair held in memory, if any. True when none is held after.
    @discardableResult
    func retryUnsaved() -> Bool {
        lock.lock()
        var events = consumeLaunchMarkerLocked()
        if let pending = unsaved, writer(pending) {
            unsaved = nil
            setMarkerLocked(false)
            if !pending.access.isEmpty { events.append(.savedLater) }
        }
        let none = unsaved == nil
        deliverLocked(events)
        lock.unlock()
        return none
    }

    /// Reads and clears the previous run's marker, once per process, before
    /// this run writes anything (`persist` and `retryUnsaved` call it too, in
    /// case they run first).
    func consumeLaunchMarker() {
        lock.lock()
        let events = consumeLaunchMarkerLocked()
        deliverLocked(events)
        lock.unlock()
    }

    /// Queues `events` for the handler; called with the lock held, so two
    /// threads' events keep the order of their transitions.
    private func deliverLocked(_ events: [KeychainReport.SessionPairOutcome]) {
        guard tracksUnsavedPairs, !events.isEmpty, let handler = eventHandler else { return }
        eventQueue.async { events.forEach(handler) }
    }

    /// Tests: waits for the events queued so far.
    func waitForEventsForTesting() { eventQueue.sync {} }

    private func consumeLaunchMarkerLocked() -> [KeychainReport.SessionPairOutcome] {
        guard tracksUnsavedPairs, !launchMarkerConsumed else { return [] }
        launchMarkerConsumed = true
        guard defaults.bool(forKey: Self.unsavedMarkerKey) else { return [] }
        defaults.removeObject(forKey: Self.unsavedMarkerKey)
        return [.pendingAtLaunch]
    }

    private func setMarkerLocked(_ on: Bool) {
        guard tracksUnsavedPairs else { return }
        if on {
            defaults.set(true, forKey: Self.unsavedMarkerKey)
        } else {
            defaults.removeObject(forKey: Self.unsavedMarkerKey)
        }
    }

    /// The newest pair, when the Keychain does not have it yet.
    var unsavedPair: Pair? {
        lock.lock(); defer { lock.unlock() }
        return unsaved
    }

    /// 1.63 (A1): the stored session as one pair, for a sign-out to revoke:
    /// the pair held unwritten if there is one, else the Keychain's two items,
    /// both read under the lock every write here holds, so never the access
    /// token of one write with the refresh token of another.
    func revocationSnapshot() -> RevocationSnapshot {
        lock.lock(); defer { lock.unlock() }
        if let unsaved {
            return RevocationSnapshot(accessToken: unsaved.access, refreshToken: unsaved.refresh)
        }
        return RevocationSnapshot(
            accessToken: KeychainHelper.load(key: AppState.tokenKeychainKey),
            refreshToken: KeychainHelper.load(key: AuthManager.refreshTokenKeychainKey)
        )
    }

    /// Tests only.
    func resetForTesting() {
        lock.lock(); unsaved = nil; lock.unlock()
    }

    /// The refresh token first: a lock between the two writes then leaves the
    /// new refresh token with an old access token, which only means one more
    /// refresh, rather than the old, spent refresh token with a new access
    /// token, which the next launch would be refused on.
    private static func write(_ pair: Pair) -> Bool {
        var wrote = true
        if let refresh = pair.refresh, !refresh.isEmpty {
            wrote = KeychainHelper.save(key: AuthManager.refreshTokenKeychainKey, value: refresh) && wrote
        } else {
            wrote = KeychainHelper.delete(key: AuthManager.refreshTokenKeychainKey) && wrote
        }
        if pair.access.isEmpty {
            wrote = KeychainHelper.delete(key: AppState.tokenKeychainKey) && wrote
        } else {
            wrote = KeychainHelper.save(key: AppState.tokenKeychainKey, value: pair.access) && wrote
        }
        return wrote
    }
}

#if os(iOS)
/// 1.61: asks iOS for time to finish auth work the app started in the
/// background (a Watch's `sendMessage` can wake or launch it): a refresh the
/// server has rotated must also be written before the app is suspended.
/// The restore, each token refresh, and the Watch's question handlers.
@MainActor
public final class BackgroundTime {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    public init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    public func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
