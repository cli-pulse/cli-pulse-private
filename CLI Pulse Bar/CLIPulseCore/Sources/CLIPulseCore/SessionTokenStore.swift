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

    static let shared = SessionTokenStore()

    private let lock = NSLock()
    private var unsaved: Pair?

    /// Write `pair`; keep it in memory if any part of the write failed.
    /// Writes are serialized, so an older pair never lands after a newer one.
    @discardableResult
    func persist(_ pair: Pair) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if Self.write(pair) {
            unsaved = nil
            return true
        }
        unsaved = pair
        return false
    }

    /// Write the pair held in memory, if any. True when none is held after.
    @discardableResult
    func retryUnsaved() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let pending = unsaved else { return true }
        if Self.write(pending) { unsaved = nil }
        return unsaved == nil
    }

    /// The newest pair, when the Keychain does not have it yet.
    var unsavedPair: Pair? {
        lock.lock(); defer { lock.unlock() }
        return unsaved
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
