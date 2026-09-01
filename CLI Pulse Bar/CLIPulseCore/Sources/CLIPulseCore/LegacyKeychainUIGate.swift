import Foundation
import Security

#if os(macOS)
/// Serializes legacy login-Keychain operations and keeps background UI off.
/// Query-level authentication flags do not reliably suppress legacy ACL
/// password sheets, so the process-wide Security setting is the final fuse.
public enum LegacyKeychainUIGate {
    private static let lock = NSRecursiveLock()

    public static func disableProcessWideUI() {
        lock.lock()
        defer { lock.unlock() }
        _ = SecKeychainSetUserInteractionAllowed(false)
    }

    public static func withUserInteractionAllowed<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try withTemporaryInteractionState(true, body)
    }

    static func withInteractionDisabled<T>(
        _ body: () throws -> T
    ) rethrows -> T {
        try withTemporaryInteractionState(false, body)
    }

    /// The getter is internal so tests can pin restoration without performing
    /// a real credential lookup. A failed state read is treated as disabled.
    static func isProcessWideUIAllowed() -> Bool {
        var allowed = DarwinBoolean(false)
        lock.lock()
        defer { lock.unlock() }
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
        else { return false }
        return allowed.boolValue
    }

    private static func withTemporaryInteractionState<T>(
        _ allowed: Bool,
        _ body: () throws -> T
    ) rethrows -> T {
        lock.lock()
        let previous = currentInteractionStateWhileLocked()
        _ = SecKeychainSetUserInteractionAllowed(allowed)
        defer {
            // Restore the value seen on entry. This makes recursive calls safe:
            // an inner background read no longer permanently disables the
            // enclosing explicit user action.
            _ = SecKeychainSetUserInteractionAllowed(previous)
            lock.unlock()
        }
        return try body()
    }

    private static func currentInteractionStateWhileLocked() -> Bool {
        var allowed = DarwinBoolean(false)
        guard SecKeychainGetUserInteractionAllowed(&allowed) == errSecSuccess
        else { return false }
        return allowed.boolValue
    }
}
#endif
