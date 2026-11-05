import XCTest
import Security
@testable import CLIPulseCore

/// 1.62: the `safe-storage` and `session-pair` Sentry reports
/// (`KeychainReports.swift`).
private final class RecordingSink: KeychainReportSink, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [KeychainReport] = []
    private var held: [@Sendable () -> Void] = []
    /// False: like a process whose Sentry never started; nothing is confirmed sent.
    var delivers = true
    func send(_ report: KeychainReport, sent done: @escaping @Sendable () -> Void) {
        lock.lock(); sent.append(report)
        let deliver = delivers
        if !deliver { held.append(done) }
        lock.unlock()
        if deliver { done() }
    }
    var reports: [KeychainReport] { lock.lock(); defer { lock.unlock() }; return sent }
    func deliverHeld() { lock.lock(); let h = held; held = []; lock.unlock(); h.forEach { $0() } }
}

private final class Clock: @unchecked Sendable {
    var now: Date
    init(_ now: Date) { self.now = now }
}

final class KeychainReporterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "keychain-reporter-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_eachOutcomeIsSentOncePerUTCDay() {
        let sink = RecordingSink()
        // 2026-11-05 23:59 UTC.
        let clock = Clock(Date(timeIntervalSince1970: 1_793_923_140))
        let reporter = KeychainReporter(sink: sink, defaults: defaults, now: { clock.now })

        reporter.report(.sessionPair(.held))
        reporter.report(.sessionPair(.held))
        reporter.report(.sessionPair(.savedLater))
        reporter.report(.safeStorage(.approvalNeeded, browser: "chrome", channel: .devid, screenLocked: false))
        // Another browser the same day: a sample of first occurrences only.
        reporter.report(.safeStorage(.approvalNeeded, browser: "brave", channel: .devid, screenLocked: false))
        XCTAssertEqual(sink.reports, [
            .sessionPair(.held), .sessionPair(.savedLater),
            .safeStorage(.approvalNeeded, browser: "chrome", channel: .devid, screenLocked: false),
        ])

        clock.now = clock.now.addingTimeInterval(120) // 00:01 UTC the next day
        reporter.report(.sessionPair(.held))
        XCTAssertEqual(sink.reports.last, .sessionPair(.held))
        XCTAssertEqual(sink.reports.count, 4)
    }

    /// A report that never reached Sentry does not use up the day, and one
    /// waiting to be sent is not queued twice.
    func test_theDayIsUsedOnlyWhenTheReportIsSent() {
        let sink = RecordingSink()
        sink.delivers = false
        let reporter = KeychainReporter(sink: sink, defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_923_140) })
        reporter.report(.sessionPair(.pendingAtLaunch))
        reporter.report(.sessionPair(.pendingAtLaunch))
        XCTAssertEqual(sink.reports.count, 1, "queued once")
        XCTAssertNil(defaults.string(forKey: KeychainReport.sessionPair(.pendingAtLaunch).dayKey))

        // The next process: its Sentry starts.
        let next = KeychainReporter(sink: sink, defaults: defaults, now: { Date(timeIntervalSince1970: 1_793_923_140) })
        sink.delivers = true
        next.report(.sessionPair(.pendingAtLaunch))
        XCTAssertEqual(sink.reports.count, 2, "the day was not used by the report that never left")
        next.report(.sessionPair(.pendingAtLaunch))
        XCTAssertEqual(sink.reports.count, 2)
    }

    /// Queued before UTC midnight, sent after it: the new day is the one used.
    func test_aReportSentAfterMidnightUsesTheDayItWasSent() {
        let sink = RecordingSink()
        sink.delivers = false
        let clock = Clock(Date(timeIntervalSince1970: 1_793_923_140)) // 11-05 23:59 UTC
        let reporter = KeychainReporter(sink: sink, defaults: defaults, now: { clock.now })
        reporter.report(.sessionPair(.held))
        clock.now = clock.now.addingTimeInterval(120)                 // 11-06 00:01 UTC
        sink.deliverHeld()
        sink.delivers = true
        reporter.report(.sessionPair(.held))
        XCTAssertEqual(sink.reports.count, 1, "already sent on 11-06")
    }
}

#if os(macOS)
final class SafeStorageReportMappingTests: XCTestCase {
    func test_eachOutcomeMapsToItsOwnWord() {
        XCTAssertEqual(
            KeychainReports.safeStorageReport(.refusedOrAuthFailed, browser: .brave, channel: .brew, screenLocked: false),
            .safeStorage(.refusedOrAuthFailed, browser: "brave", channel: .brew, screenLocked: false))
        XCTAssertEqual(
            KeychainReports.safeStorageReport(.approvalNeeded, browser: .chrome, channel: .devid, screenLocked: true),
            .safeStorage(.approvalNeeded, browser: "chrome", channel: .devid, screenLocked: true))
        XCTAssertEqual(
            KeychainReport.safeStorage(.approvalNeeded, browser: "arc", channel: .devid, screenLocked: nil)
                .tags["screen_locked"], "unknown")
    }
}
#endif

final class KeychainReportScopeTests: XCTestCase {
    func test_theEventAddsOnlyClosedSetTagsAndNoBreadcrumbs() {
        let current = Scope()
        current.addBreadcrumb(Breadcrumb(level: .info, category: "http"))
        let event = Scope(scope: current)
        let before = event.serialize()
        XCTAssertEqual((before["breadcrumbs"] as? [Any])?.count, 1, "control")

        let report = KeychainReport.safeStorage(.refusedOrAuthFailed, browser: "chrome", channel: .devid, screenLocked: false)
        SentryKeychainReportSink.configure(event, for: report)
        let after = event.serialize()

        XCTAssertNil(after["breadcrumbs"])
        XCTAssertEqual(after["tags"] as? [String: String],
                       ["ss_outcome": "refused_or_auth_failed", "ss_browser": "chrome", "channel": "devid",
                        "screen_locked": "false"])
        XCTAssertEqual(after["fingerprint"] as? [String], ["safe-storage", "refused_or_auth_failed"])
        XCTAssertEqual(after["level"] as? String, "warning")
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), ["tags", "fingerprint", "level"])
        XCTAssertEqual(SentryKeychainReportSink.message(for: report), "safe-storage refused_or_auth_failed")
    }

    /// The scrubber blanks tags whose key contains `keychain`, `token`, …: the
    /// keys and the message must come through it unchanged.
    func test_theScrubberLeavesTheReportAlone() {
        let reports: [KeychainReport] = KeychainReport.SessionPairOutcome.allCases.map { .sessionPair($0) }
            + KeychainReport.SafeStorageOutcome.allCases.map { .safeStorage($0, browser: "edge", channel: .brew, screenLocked: true) }
        for report in reports {
            let event = Event(level: .warning)
            event.message = SentryMessage(formatted: SentryKeychainReportSink.message(for: report))
            event.tags = report.tags
            let scrubbed = SentryLogger.scrub(event: event)
            XCTAssertEqual(scrubbed?.tags, report.tags, "\(report)")
            XCTAssertEqual(scrubbed?.message?.formatted, SentryKeychainReportSink.message(for: report))
        }
    }
}

final class KeychainReportPrivacyTests: XCTestCase {
    /// PRIVACY.md says what these reports carry; a change to either must
    /// change the other.
    func test_privacyNamesTheReportsAndWhatTheyCarry() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let policy = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for claim in [
            "Since v1.62 the Mac app outside the App Store also sends an error report",
            "a browser's \"Safe Storage\" item",
            "the Keychain did not accept the new sign-in tokens",
            "Each of these outcomes is sent at most once a UTC day",
            "(the stack trace, the app and OS version, the device details and the SDK's random installation identifier)",
            "whether the screen was locked (when the system says)",
            "the browser's name from a fixed list, the install channel and whether the screen was locked (when the system says)",
            "It has no breadcrumbs, no tokens, no error text from the system",
        ] {
            XCTAssertTrue(policy.contains(claim), "PRIVACY.md no longer says \"\(claim)\"")
        }
    }
}

final class SessionTokenStoreReportTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    private var keychainAccepts = true
    private var events: [KeychainReport.SessionPairOutcome] = []
    private let lock = NSLock()

    override func setUp() {
        super.setUp()
        suite = "session-pair-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        keychainAccepts = true
        events = []
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store(tracks: Bool = true) -> SessionTokenStore {
        let store = SessionTokenStore(defaults: defaults, tracksUnsavedPairs: tracks) { [unowned self] _ in
            self.keychainAccepts
        }
        store.onEvent = { [unowned self] event in
            self.lock.lock(); self.events.append(event); self.lock.unlock()
        }
        stores.append(store)
        return store
    }

    private let pair = SessionTokenStore.Pair(access: "a1", refresh: "r1")
    private let newer = SessionTokenStore.Pair(access: "a2", refresh: "r2")
    private let signedOut = SessionTokenStore.Pair(access: "", refresh: nil)
    private var marker: Bool { defaults.bool(forKey: SessionTokenStore.unsavedMarkerKey) }
    private var stores: [SessionTokenStore] = []

    /// The events delivered so far, once every store's queue has emptied.
    private func drained() -> [KeychainReport.SessionPairOutcome] {
        stores.forEach { $0.waitForEventsForTesting() }
        lock.lock(); defer { lock.unlock() }
        return events
    }

    func test_aRefusedWriteIsHeldOnce_andSavedLater() {
        let s = store()
        keychainAccepts = false
        s.persist(pair)
        s.persist(newer)
        XCTAssertEqual(drained(), [.held], "one hold, however many pairs it holds")
        XCTAssertTrue(marker)
        XCTAssertEqual(s.unsavedPair, newer)

        XCTAssertFalse(s.retryUnsaved())
        XCTAssertEqual(drained(), [.held])
        keychainAccepts = true
        XCTAssertTrue(s.retryUnsaved())
        XCTAssertEqual(drained(), [.held, .savedLater])
        XCTAssertFalse(marker)
    }

    func test_aNewPairWrittenOverAHeldOne_clearsTheMarkerWithoutSavedLater() {
        let s = store()
        keychainAccepts = false
        s.persist(pair)
        keychainAccepts = true
        s.persist(newer)
        XCTAssertEqual(drained(), [.held])
        XCTAssertFalse(marker)
        XCTAssertNil(s.unsavedPair)
    }

    /// A sign-out the Keychain refuses still means the user left: nothing to
    /// report at the next launch, and writing the empty pair later is not a
    /// session saved.
    func test_aRefusedSignOut_clearsTheMarker_andReportsNothing() {
        let s = store()
        keychainAccepts = false
        s.persist(pair)
        s.persist(signedOut)
        XCTAssertFalse(marker)
        keychainAccepts = true
        s.retryUnsaved()
        XCTAssertEqual(drained(), [.held])
    }

    func test_aRefusedSignOutAlone_isNotAHold() {
        let s = store()
        keychainAccepts = false
        s.persist(signedOut)
        XCTAssertEqual(drained(), [])
        XCTAssertFalse(marker)
    }

    func test_aRunThatEndedHoldingAPair_isReportedOnceAtTheNextLaunch() {
        keychainAccepts = false
        store().persist(pair)
        XCTAssertTrue(marker)
        _ = drained(); events = []

        // The next process: a new store on the same defaults.
        let next = store()
        next.consumeLaunchMarker()
        next.consumeLaunchMarker()
        XCTAssertEqual(drained(), [.pendingAtLaunch])
        XCTAssertFalse(marker)
    }

    /// If a write comes before the explicit launch check, the old marker is
    /// still read first, not overwritten.
    func test_theLaunchMarkerIsReadBeforeTheFirstWrite() {
        keychainAccepts = false
        store().persist(pair)
        _ = drained(); events = []
        keychainAccepts = true
        store().persist(newer)
        XCTAssertEqual(drained(), [.pendingAtLaunch])
    }

    func test_theMacTracksNothing() {
        let s = store(tracks: false)
        keychainAccepts = false
        s.persist(pair)
        keychainAccepts = true
        s.retryUnsaved()
        XCTAssertEqual(drained(), [])
        XCTAssertFalse(marker)
        XCTAssertFalse(SessionTokenStore.isIPhone, "swift test runs on the Mac")
    }
}

final class SentryLoggerAfterStartTests: XCTestCase {
    override func tearDown() {
        SentryLogger.resetStartStateForTesting()
        super.tearDown()
    }

    func test_aReportMadeBeforeTheStartRunsAfterIt_andLaterOnesRunAtOnce() {
        SentryLogger.resetStartStateForTesting()
        let ran = NSLockedBox<[Int]>([])
        SentryLogger.afterStart { ran.withLock { $0.append(1) } }
        XCTAssertEqual(ran.withLock { $0 }, [])
        SentryLogger.markStartedForTesting()
        XCTAssertEqual(ran.withLock { $0 }, [1])
        SentryLogger.afterStart { ran.withLock { $0.append(2) } }
        XCTAssertEqual(ran.withLock { $0 }, [1, 2])
    }

    func test_thePendingQueueIsBounded() {
        SentryLogger.resetStartStateForTesting()
        let ran = NSLockedBox(0)
        for _ in 0..<(SentryLogger.maxPendingReports + 5) {
            SentryLogger.afterStart { ran.withLock { $0 += 1 } }
        }
        SentryLogger.markStartedForTesting()
        XCTAssertEqual(ran.withLock { $0 }, SentryLogger.maxPendingReports)
    }
}

#if os(macOS)
/// Where the Safe Storage outcomes come from: the Keychain's own statuses,
/// never an error's text.
final class SafeStorageOutcomeTests: XCTestCase {
    private var seen: NSLockedBox<[BrowserCookieKeychainOutcome]>!

    override func setUp() {
        super.setUp()
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        let box = NSLockedBox<[BrowserCookieKeychainOutcome]>([])
        seen = box
        BrowserCookieKeychainOutcomeHandler.handler = { _, outcome in box.withLock { $0.append(outcome) } }
    }

    override func tearDown() {
        BrowserCookieKeychainOutcomeHandler.handler = nil
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        super.tearDown()
    }

    private func read(noUI: OSStatus, dialog: OSStatus, interactive: Bool) {
        _ = try? ChromeCookieImporter.chromeSafeStorageKey(
            for: .chrome, allowInteraction: interactive,
            passwordLookup: { _, _, ui in
                let status = ui ? dialog : noUI
                return (status, status == errSecSuccess ? "pw" : nil)
            })
    }

    private var outcomes: [BrowserCookieKeychainOutcome] { seen.withLock { $0 } }

    func test_aBackgroundReadThatNeedsADialog_isApprovalNeeded() {
        read(noUI: errSecInteractionNotAllowed, dialog: errSecSuccess, interactive: false)
        XCTAssertEqual(outcomes, [.approvalNeeded])
    }

    func test_aCancelledOrFailedDialog_isRefused() {
        read(noUI: errSecInteractionNotAllowed, dialog: errSecUserCanceled, interactive: true)
        ChromeCookieImporter.resetSafeStorageKeyCacheForTesting()
        read(noUI: errSecInteractionNotAllowed, dialog: errSecAuthFailed, interactive: true)
        XCTAssertEqual(outcomes, [.refusedOrAuthFailed, .refusedOrAuthFailed])
    }

    /// Only "a dialog would be needed" counts; any other Keychain error in the
    /// background is not reported as one.
    func test_aBackgroundReadFailingOtherwise_isNotApprovalNeeded() {
        read(noUI: errSecNotAvailable, dialog: errSecSuccess, interactive: false)
        read(noUI: errSecParam, dialog: errSecSuccess, interactive: false)
        XCTAssertEqual(outcomes, [])
    }

    func test_noItem_anAllowedDialog_andAnUnansweredDialog_reportNothing() {
        read(noUI: errSecItemNotFound, dialog: errSecItemNotFound, interactive: true)
        read(noUI: errSecItemNotFound, dialog: errSecItemNotFound, interactive: false)
        read(noUI: errSecInteractionNotAllowed, dialog: errSecInteractionNotAllowed, interactive: true)
        read(noUI: errSecInteractionNotAllowed, dialog: errSecSuccess, interactive: true)
        XCTAssertEqual(outcomes, [])
    }
}
#endif
