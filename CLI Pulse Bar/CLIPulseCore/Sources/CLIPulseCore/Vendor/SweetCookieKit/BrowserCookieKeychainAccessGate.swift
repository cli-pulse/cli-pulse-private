// Vendored from steipete/SweetCookieKit 0.4.1 (MIT, © Peter Steinberger)
// https://github.com/steipete/SweetCookieKit — see ./LICENSE for the
// full MIT notice. Source-vendored (not an SPM dependency) because
// SweetCookieKit's Package.swift requires swift-tools 6.2 while CI runs
// Swift 6.1; vendoring removes the manifest from the resolution graph.
// Whole file is `#if os(macOS)`-wrapped so it never compiles on
// iOS/watchOS (same isolation the `.when(platforms:[.macOS])` SPM
// condition provided); CLIPulseCore links sqlite3 on macOS for this.

#if os(macOS)

import Foundation

#if os(macOS)
/// A foreground action grants at most one interactive Safe Storage read, even
/// when a collector probes several browser labels or starts child tasks.
public final class BrowserCredentialInteractionPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var consumed = false

    public init() {}

    fileprivate var isAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !consumed
    }

    fileprivate func consume() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return true
    }
}

/// Opt-in switch for disabling Keychain access in host apps.
public enum BrowserCookieKeychainAccessGate {
    public nonisolated(unsafe) static var isDisabled: Bool = false

    /// One-shot authority carried only by an explicit foreground task. Launch,
    /// helper, widget, and timer work inherit nil. Child tasks may inherit the
    /// permit, but the shared token can be consumed only once.
    @TaskLocal public static var interactionPermit:
        BrowserCredentialInteractionPermit? = nil

    public static var allowsInteraction: Bool {
        interactionPermit?.isAvailable ?? false
    }

    static func consumeInteractionPermit() -> Bool {
        interactionPermit?.consume() ?? false
    }
}
#endif

#endif
