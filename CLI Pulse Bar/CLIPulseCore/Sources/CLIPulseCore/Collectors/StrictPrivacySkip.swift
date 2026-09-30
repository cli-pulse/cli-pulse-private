import Foundation

/// v1.55 — a read Strict privacy mode stopped, so a provider row can say that
/// instead of something false.
///
/// Strict privacy mode (Settings › Privacy) means CLI Pulse reads no other
/// app's secrets on its own. A provider whose only credential is one of those
/// then has none, and the error its collector throws for a missing credential
/// is shown as "Authentication failed … its saved credential was rejected"
/// (a cookie provider set to read its cookie from a browser, Cursor by
/// default) or "Not set up" (Zed). Neither is true: nothing was rejected, and
/// the provider may be set up; CLI Pulse did not look, because the user asked
/// it not to.
///
/// Kept out of `#if os(macOS)` like the rest of the collector vocabulary:
/// `CookieResolver`, which notes the browser skip, compiles everywhere.
public enum StrictPrivacySkip: Sendable, Equatable {
    /// A browser's cookie store, and the "Safe Storage" keychain item that
    /// decrypts it (`CookieResolver`'s automatic import).
    case browserCookies
    /// Another app's own keychain item (Zed's).
    case keychainItem

    /// How a provider row reports it (`CollectorOutcomePresentation`).
    public var notReadyReason: CollectorNotReadyReason {
        switch self {
        case .browserCookies: return .strictPrivacyModeCookies
        case .keychainItem: return .strictPrivacyModeKeychain
        }
    }
}

/// The reads Strict privacy mode stopped during one collector run.
///
/// The collector drivers (`DataRefreshManager.runOneCollectorWithOutcome`,
/// `CollectorRunner.run`, the provider editor's Test button) bind a fresh log
/// to the run's task (`$current`) and read it when the run fails;
/// `CookieResolver` notes a skipped browser import in whichever log is bound.
/// A task-local rather than a return value because the ~17 cookie collectors
/// each turn a missing cookie into their own error, and all of them would
/// have to learn a new one; this way none does, and a new cookie collector
/// is covered without knowing about it. Concurrent runs each bind their own.
public final class StrictPrivacySkipLog: @unchecked Sendable {
    @TaskLocal public static var current: StrictPrivacySkipLog?

    private let lock = NSLock()
    private var noted: [StrictPrivacySkip] = []

    public init() {}

    /// Notes `skip` in the run this task belongs to. Outside a run, nothing.
    public static func note(_ skip: StrictPrivacySkip) {
        current?.append(skip)
    }

    /// What was noted, in order, each once.
    public var skips: [StrictPrivacySkip] {
        lock.withLock { noted }
    }

    private func append(_ skip: StrictPrivacySkip) {
        lock.withLock {
            if !noted.contains(skip) { noted.append(skip) }
        }
    }
}

/// Thrown by a collector whose one credential Strict privacy mode stops it
/// reading (Zed's keychain item), in place of a "no credentials" error that
/// would be false. Its description is the row's hint, so the provider
/// editor's Test button says the same thing as the row.
public struct StrictPrivacyModeSkipped: Error, LocalizedError, Sendable, Equatable {
    public let skip: StrictPrivacySkip
    /// The provider's display name, for the hint.
    public let provider: String

    public init(_ skip: StrictPrivacySkip, provider: String) {
        self.skip = skip
        self.provider = provider
    }

    public var errorDescription: String? {
        switch skip {
        case .browserCookies: return L10n.collectorStatus.strictPrivacyModeCookieHint(provider)
        case .keychainItem: return L10n.collectorStatus.strictPrivacyModeKeychainHint(provider)
        }
    }
}
