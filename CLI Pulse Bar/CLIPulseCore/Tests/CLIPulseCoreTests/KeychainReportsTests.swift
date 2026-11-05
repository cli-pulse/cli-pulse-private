import XCTest
import Security
@testable import CLIPulseCore

/// 1.62: the `safe-storage` and `session-pair` Sentry reports
/// (`KeychainReports.swift`).
private final class RecordingSink: KeychainReportSink, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [KeychainReport] = []
    func send(_ report: KeychainReport) { lock.lock(); sent.append(report); lock.unlock() }
    var reports: [KeychainReport] { lock.lock(); defer { lock.unlock() }; return sent }
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
        // 2026-11-06 23:59 UTC.
        let clock = Clock(Date(timeIntervalSince1970: 1_793_923_140))
        let reporter = KeychainReporter(sink: sink, defaults: defaults, now: { clock.now })

        reporter.report(.sessionPair(.held))
        reporter.report(.sessionPair(.held))
        reporter.report(.sessionPair(.savedLater))
        reporter.report(.safeStorage(.approvalNeeded, browser: "chrome", channel: .devid))
        // Another browser the same day: a sample of first occurrences only.
        reporter.report(.safeStorage(.approvalNeeded, browser: "brave", channel: .devid))
        XCTAssertEqual(sink.reports, [
            .sessionPair(.held), .sessionPair(.savedLater),
            .safeStorage(.approvalNeeded, browser: "chrome", channel: .devid),
        ])

        clock.now = clock.now.addingTimeInterval(120) // 00:01 UTC the next day
        reporter.report(.sessionPair(.held))
        XCTAssertEqual(sink.reports.last, .sessionPair(.held))
        XCTAssertEqual(sink.reports.count, 4)
    }
}

final class KeychainReportScopeTests: XCTestCase {
    func test_theEventAddsOnlyClosedSetTagsAndNoBreadcrumbs() {
        let current = Scope()
        current.addBreadcrumb(Breadcrumb(level: .info, category: "http"))
        let event = Scope(scope: current)
        let before = event.serialize()
        XCTAssertEqual((before["breadcrumbs"] as? [Any])?.count, 1, "control")

        let report = KeychainReport.safeStorage(.refusedOrAuthFailed, browser: "chrome", channel: .devid)
        SentryKeychainReportSink.configure(event, for: report)
        let after = event.serialize()

        XCTAssertNil(after["breadcrumbs"])
        XCTAssertEqual(after["tags"] as? [String: String],
                       ["ss_outcome": "refused_or_auth_failed", "ss_browser": "chrome", "channel": "devid"])
        XCTAssertEqual(after["fingerprint"] as? [String], ["safe-storage", "refused_or_auth_failed"])
        XCTAssertEqual(after["level"] as? String, "warning")
        XCTAssertEqual(Set(after.keys).subtracting(before.keys), ["tags", "fingerprint", "level"])
        XCTAssertEqual(SentryKeychainReportSink.message(for: report), "safe-storage refused_or_auth_failed")
    }

    /// The scrubber blanks tags whose key contains `keychain`, `token`, …: the
    /// keys and the message must come through it unchanged.
    func test_theScrubberLeavesTheReportAlone() {
        let reports: [KeychainReport] = KeychainReport.SessionPairOutcome.allCases.map { .sessionPair($0) }
            + KeychainReport.SafeStorageOutcome.allCases.map { .safeStorage($0, browser: "edge", channel: .brew) }
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
            "Each kind is sent at most once a day",
            "the browser's name from a fixed list and the install channel",
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
        return store
    }

    private let pair = SessionTokenStore.Pair(access: "a1", refresh: "r1")
    private let newer = SessionTokenStore.Pair(access: "a2", refresh: "r2")
    private let signedOut = SessionTokenStore.Pair(access: "", refresh: nil)
    private var marker: Bool { defaults.bool(forKey: SessionTokenStore.unsavedMarkerKey) }

    func test_aRefusedWriteIsHeldOnce_andSavedLater() {
        let s = store()
        keychainAccepts = false
        s.persist(pair)
        s.persist(newer)
        XCTAssertEqual(events, [.held], "one hold, however many pairs it holds")
        XCTAssertTrue(marker)
        XCTAssertEqual(s.unsavedPair, newer)

        XCTAssertFalse(s.retryUnsaved())
        XCTAssertEqual(events, [.held])
        keychainAccepts = true
        XCTAssertTrue(s.retryUnsaved())
        XCTAssertEqual(events, [.held, .savedLater])
        XCTAssertFalse(marker)
    }

    func test_aNewPairWrittenOverAHeldOne_clearsTheMarkerWithoutSavedLater() {
        let s = store()
        keychainAccepts = false
        s.persist(pair)
        keychainAccepts = true
        s.persist(newer)
        XCTAssertEqual(events, [.held])
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
        XCTAssertEqual(events, [.held])
    }

    func test_aRefusedSignOutAlone_isNotAHold() {
        let s = store()
        keychainAccepts = false
        s.persist(signedOut)
        XCTAssertEqual(events, [])
        XCTAssertFalse(marker)
    }

    func test_aRunThatEndedHoldingAPair_isReportedOnceAtTheNextLaunch() {
        keychainAccepts = false
        store().persist(pair)
        XCTAssertTrue(marker)
        events = []

        // The next process: a new store on the same defaults.
        let next = store()
        next.consumeLaunchMarker()
        next.consumeLaunchMarker()
        XCTAssertEqual(events, [.pendingAtLaunch])
        XCTAssertFalse(marker)
    }

    /// If a write comes before the explicit launch check, the old marker is
    /// still read first, not overwritten.
    func test_theLaunchMarkerIsReadBeforeTheFirstWrite() {
        keychainAccepts = false
        store().persist(pair)
        events = []
        keychainAccepts = true
        store().persist(newer)
        XCTAssertEqual(events, [.pendingAtLaunch])
    }

    func test_theMacTracksNothing() {
        let s = store(tracks: false)
        keychainAccepts = false
        s.persist(pair)
        keychainAccepts = true
        s.retryUnsaved()
        XCTAssertEqual(events, [])
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

    func test_noItem_anAllowedDialog_andAnUnansweredDialog_reportNothing() {
        read(noUI: errSecItemNotFound, dialog: errSecItemNotFound, interactive: true)
        read(noUI: errSecItemNotFound, dialog: errSecItemNotFound, interactive: false)
        read(noUI: errSecInteractionNotAllowed, dialog: errSecInteractionNotAllowed, interactive: true)
        read(noUI: errSecInteractionNotAllowed, dialog: errSecSuccess, interactive: true)
        XCTAssertEqual(outcomes, [])
    }
}
#endif
