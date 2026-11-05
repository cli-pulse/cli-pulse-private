import Foundation
#if os(macOS)
import CoreGraphics
#endif

/// 1.62: two Keychain outcomes we could not see in 1.61's data, reported to
/// Sentry as closed-set words only.
///
/// - `safe-storage` (Mac, Developer ID): the Keychain refused a browser's
///   "Safe Storage" item on a refresh the person started
///   (`refused_or_auth_failed`), or a background refresh found one that would
///   need a dialog (`approval_needed`, the 1.60 N2 path). Answers plan 1.62 A4:
///   do Developer ID Macs still meet these after N2?
/// - `session-pair` (iPhone): the Keychain did not take the session's new
///   tokens and the app held them in memory (`held`, 1.61 #738), wrote them
///   later (`saved_later`), or a launch found that the previous run ended still
///   holding some (`pending_at_launch`). Answers A2: does the hold happen, and
///   does a run end before the write? `pending_at_launch` does not prove the
///   session was lost: the refresh token may have been written.
///
/// Each outcome is sent at most once per UTC day, so these are a sample of
/// first occurrences: none in a day does not mean it never happened.
/// PRIVACY.md describes exactly these.
public enum KeychainReport: Equatable, Sendable {
    /// `browser` is a `Browser` raw value (a fixed list; never a profile name).
    /// `screenLocked`: a locked login keychain answers like an item that needs
    /// approval. The screen's lock is a hint only: a keychain can lock on its
    /// own timer while the screen is not, so `approval_needed` with the screen
    /// unlocked still does not prove the item needed approval. Nil when the
    /// session would not say.
    case safeStorage(SafeStorageOutcome, browser: String, channel: DistributionChannel, screenLocked: Bool?)
    case sessionPair(SessionPairOutcome)

    public enum SafeStorageOutcome: String, Sendable, CaseIterable {
        case refusedOrAuthFailed = "refused_or_auth_failed"
        case approvalNeeded = "approval_needed"
    }

    public enum SessionPairOutcome: String, Sendable, CaseIterable {
        case held
        case savedLater = "saved_later"
        case pendingAtLaunch = "pending_at_launch"
    }

    /// One fixed name per kind; the message is this and the outcome.
    var eventName: String {
        switch self {
        case .safeStorage: return "safe-storage"
        case .sessionPair: return "session-pair"
        }
    }

    var outcome: String {
        switch self {
        case .safeStorage(let outcome, _, _, _): return outcome.rawValue
        case .sessionPair(let outcome): return outcome.rawValue
        }
    }

    /// Tag keys avoid `SentryLogger`'s scrubbed fragments (`keychain`,
    /// `token`, …), or the scrubber would blank them.
    var tags: [String: String] {
        switch self {
        case let .safeStorage(outcome, browser, channel, screenLocked):
            return ["ss_outcome": outcome.rawValue, "ss_browser": browser, "channel": channel.rawValue,
                    "screen_locked": screenLocked.map { $0 ? "true" : "false" } ?? "unknown"]
        case .sessionPair(let outcome):
            return ["pair_outcome": outcome.rawValue]
        }
    }

    /// The once-a-day latch's key, one per kind and outcome. `cli_pulse_` keeps
    /// it across a move from the App Store build to the Developer ID one.
    var dayKey: String { "cli_pulse_keychain_report_day_\(eventName)_\(outcome)" }
}

/// Where the reports go. A protocol so the tests see every report without
/// starting Sentry (DEBUG builds never start it).
protocol KeychainReportSink: Sendable {
    /// `sent` runs once the report has actually been handed to Sentry.
    func send(_ report: KeychainReport, sent: @escaping @Sendable () -> Void)
}

struct SentryKeychainReportSink: KeychainReportSink {
    func send(_ report: KeychainReport, sent: @escaping @Sendable () -> Void) {
        // A report from launch can come before `SentrySDK.start` has finished.
        SentryLogger.afterStart {
            SentrySDK.capture(message: Self.message(for: report)) { scope in
                Self.configure(scope, for: report)
            }
            sent()
        }
    }

    static func message(for report: KeychainReport) -> String {
        "\(report.eventName) \(report.outcome)"
    }

    /// Everything the report adds to the SDK's standard envelope; this event
    /// only (sentry-cocoa hands the block a copy of the scope).
    static func configure(_ scope: Scope, for report: KeychainReport) {
        scope.setLevel(.warning)
        scope.setFingerprint([report.eventName, report.outcome])
        for (key, value) in report.tags {
            scope.setTag(value: value, key: key)
        }
        scope.clearBreadcrumbs()
    }
}

/// Sends each report at most once per UTC day for its kind and outcome. The
/// day is used up only when the report was really sent, so a process that
/// ends before Sentry starts (a short background launch) does not spend it.
final class KeychainReporter: @unchecked Sendable {
    static let shared = KeychainReporter(sink: SentryKeychainReportSink(), defaults: .standard, now: { Date() })

    private let sink: any KeychainReportSink
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Reports handed to the sink and not sent yet, so they are not queued twice.
    private var inFlight: Set<String> = []

    init(sink: any KeychainReportSink, defaults: UserDefaults, now: @escaping @Sendable () -> Date) {
        self.sink = sink
        self.defaults = defaults
        self.now = now
    }

    func report(_ report: KeychainReport) {
        let today = DayKey.string(from: now(), in: DayKey.utc)
        let key = report.dayKey
        lock.lock()
        let due = defaults.string(forKey: key) != today && !inFlight.contains(key)
        if due { inFlight.insert(key) }
        lock.unlock()
        guard due else { return }
        sink.send(report) { [self] in
            // The day it actually went: a report queued before midnight and
            // sent after it uses the new day.
            let sentDay = DayKey.string(from: now(), in: DayKey.utc)
            lock.lock()
            defaults.set(sentDay, forKey: key)
            inFlight.remove(key)
            lock.unlock()
        }
    }
}

public enum KeychainReports {
    #if os(macOS)
    /// The Mac app, once Sentry is started. Not the App Store build: its
    /// sandbox never reaches a browser's Keychain item. Not the Login Item
    /// helper either, which never calls this (it has no Sentry).
    public static func installForMac() {
        guard !MASSandboxGate.isSandboxed else { return }
        let channel = DistributionChannel.detectCurrent()
        BrowserCookieKeychainOutcomeHandler.handler = { browser, outcome in
            KeychainReporter.shared.report(
                safeStorageReport(outcome, browser: browser, channel: channel, screenLocked: isScreenLocked()))
        }
    }

    static func safeStorageReport(
        _ outcome: BrowserCookieKeychainOutcome, browser: Browser,
        channel: DistributionChannel, screenLocked: Bool?
    ) -> KeychainReport {
        let mapped: KeychainReport.SafeStorageOutcome
        switch outcome {
        case .refusedOrAuthFailed: mapped = .refusedOrAuthFailed
        case .approvalNeeded: mapped = .approvalNeeded
        }
        return .safeStorage(mapped, browser: browser.rawValue, channel: channel, screenLocked: screenLocked)
    }

    /// Whether the login session's screen is locked right now; nil when there
    /// is no session dictionary. `CGSSessionScreenIsLocked` is undocumented and
    /// present only while locked, so its absence in a session reads as unlocked.
    static func isScreenLocked() -> Bool? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
    #endif

    #if os(iOS)
    /// The iPhone app, once Sentry is started and before `AppState` restores
    /// the session: reports a pair the previous run left unwritten, then every
    /// hold and late write from here on.
    public static func installForIPhone() {
        SessionTokenStore.shared.onEvent = { KeychainReporter.shared.report(.sessionPair($0)) }
        SessionTokenStore.shared.consumeLaunchMarker()
    }
    #endif
}
