#if os(macOS)
import Security
import XCTest
@testable import CLIPulseCore

/// 2026-11-24: with Settings › Privacy › "Renew Claude Code's sign-in" on,
/// the app starts Claude Code so it renews its own expired login, and checks
/// the result by reading the item back without a dialog.
///
/// No real process, keychain, clock or defaults: the run loop is driven with a
/// fake child and a fake clock, the coordinator with an injected environment,
/// and the read-back through the real `readKeychainCredentials` decision logic
/// with `SecItemCopyMatching` replaced (the query flags are captured).
final class ClaudeSignInRenewalTests: XCTestCase {

    // MARK: - Policy

    func test_backoff_table() {
        let minutes = (0...9).map { Int(ClaudeSignInRenewalPolicy.interval(afterFailures: $0) / 60) }
        XCTAssertEqual(minutes, [30, 30, 60, 120, 240, 480, 960, 1440, 1440, 1440])
    }

    func test_firstAttempt_isAllowed() {
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: Date(), record: ClaudeSignInRenewalRecord(), userAsked: false, expiredLogin: nil))
    }

    func test_thirtyMinutesAfterAnyAttempt_beforeTheNext() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let record = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 0, expiredLoginAtLastAttempt: "a")
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(29 * 60), record: record, userAsked: false, expiredLogin: "a"))
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(30 * 60), record: record, userAsked: false, expiredLogin: "a"))
    }

    func test_failuresInARow_holdTheNextOneBack() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let record = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 3, expiredLoginAtLastAttempt: "a")
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(119 * 60), record: record, userAsked: false, expiredLogin: "a"))
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(120 * 60), record: record, userAsked: false, expiredLogin: "a"))
    }

    /// Claude Code started by the Claude desktop app rewrites the item without
    /// renewing it, so only a different expired login lifts the backoff.
    func test_aDifferentExpiredLogin_liftsTheBackoff_butNotTheFloor() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let record = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 7, expiredLoginAtLastAttempt: "a")
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(10 * 60), record: record, userAsked: false, expiredLogin: "b"))
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(31 * 60), record: record, userAsked: false, expiredLogin: "b"))
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(31 * 60), record: record, userAsked: false, expiredLogin: "a"))
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(31 * 60), record: record, userAsked: false, expiredLogin: nil))
        let unknown = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 7, expiredLoginAtLastAttempt: nil)
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(31 * 60), record: unknown, userAsked: false, expiredLogin: "b"))
    }

    func test_aRefreshTheUserClicked_skipsTheBackoff_notTheMinute() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let record = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 7, expiredLoginAtLastAttempt: "a")
        XCTAssertFalse(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(59), record: record, userAsked: true, expiredLogin: "a"))
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(60), record: record, userAsked: true, expiredLogin: "a"))
    }

    func test_aClockSetBack_doesNotWaitForTheClockToCatchUp() {
        let last = Date(timeIntervalSince1970: 1_000_000)
        let record = ClaudeSignInRenewalRecord(lastAttemptAt: last, consecutiveFailures: 7, expiredLoginAtLastAttempt: "a")
        XCTAssertTrue(ClaudeSignInRenewalPolicy.allows(
            now: last.addingTimeInterval(-3600), record: record, userAsked: false, expiredLogin: "a"))
    }

    // MARK: - Screen

    func test_screensThatWantAnAnswer_endTheRun() {
        for text in [
            "Select login method:",
            "Not logged in · Please run /login",
            "Session expired. Please run /login to sign in again.",
            "Quick safety check: is this a project you created or one you trust?",
            "Yes, I trust this folder",
            "New MCP server found in .mcp.json",
            "Invalid API key",
        ] {
            XCTAssertTrue(ClaudeSignInRenewalScreen.shouldStop(text.lowercased()), text)
        }
    }

    func test_theIdlePrompt_keepsTheRunGoing() {
        let idle = "❯ Try \"edit <filepath> to…\"\n⏵⏵ auto mode on (shift+tab to cycle) · ← for agents"
        XCTAssertFalse(ClaudeSignInRenewalScreen.shouldStop(idle.lowercased()))
    }

    func test_onlyTheLatestOutputIsMatched() {
        var window = ClaudeSignInRenewalScreen.appending(Data("select login method".utf8), to: Data())
        XCTAssertTrue(ClaudeSignInRenewalScreen.shouldStop(ClaudeSignInRenewalScreen.normalized(window)))
        window = ClaudeSignInRenewalScreen.appending(
            Data(repeating: UInt8(ascii: "x"), count: ClaudeSignInRenewalScreen.windowBytes), to: window)
        XCTAssertEqual(window.count, ClaudeSignInRenewalScreen.windowBytes)
        XCTAssertFalse(ClaudeSignInRenewalScreen.shouldStop(ClaudeSignInRenewalScreen.normalized(window)))
    }

    func test_wordsRunTogether_stillMatch() {
        XCTAssertTrue(ClaudeSignInRenewalScreen.shouldStop("selectloginmethod:"))
        XCTAssertTrue(ClaudeSignInRenewalScreen.shouldStop("notloggedin·pleaserun/login"))
    }

    func test_ansiIsStrippedBeforeMatching() {
        let window = Data("\u{1b}[1mSelect\u{1b}[0m login method:".utf8)
        XCTAssertTrue(ClaudeSignInRenewalScreen.shouldStop(ClaudeSignInRenewalScreen.normalized(window)))
    }

    // MARK: - Verdict

    func test_verdict() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func creds(_ expires: Date?) -> ClaudeCredentials.Creds {
            ClaudeCredentials.Creds(accessToken: "t", rateLimitTier: nil, expiresAt: expires)
        }
        XCTAssertEqual(ClaudeSignInRenewal.verdict(
            creds: creds(now.addingTimeInterval(8 * 3600)), miss: nil, now: now), .current)
        XCTAssertEqual(ClaudeSignInRenewal.verdict(
            creds: creds(now.addingTimeInterval(60)), miss: nil, now: now), .stillExpired)
        XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: creds(nil), miss: nil, now: now), .notReadableQuietly,
                       "without an expiry it may be the old token")
        XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: nil, miss: .expiredLogin, now: now), .stillExpired)
        XCTAssertEqual(ClaudeSignInRenewal.verdict(
            creds: nil, miss: .status(errSecInteractionNotAllowed), now: now), .notReadableQuietly)
        XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: nil, miss: nil, now: now), .notReadableQuietly)
    }

    func test_verdict_theExpiredTokenWithANewExpiry_isNotARenewal() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let same = ClaudeCredentials.Creds(accessToken: "old", rateLimitTier: nil, expiresAt: now.addingTimeInterval(8 * 3600))
        let old = ClaudeOAuthBackoffState.fingerprint(forToken: "old")
        XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: same, miss: nil, now: now, excluding: old), .stillExpired)
        let new = ClaudeCredentials.Creds(accessToken: "new", rateLimitTier: nil, expiresAt: now.addingTimeInterval(8 * 3600))
        XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: new, miss: nil, now: now, excluding: old), .current)
    }

    // MARK: - Screen lock

    func test_unlockedOnlyWhenThisUserIsAtTheConsole() {
        let key = ClaudeSignInRenewal.onConsoleKey
        XCTAssertEqual(key, "kCGSSessionOnConsoleKey", "the key as CGSessionCopyCurrentDictionary spells it")
        XCTAssertNil(ClaudeSignInRenewal.screenLocked(session: nil))
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: [key: true]), false)
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: [key: true, "CGSSessionScreenIsLocked": true]), true)
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: [key: false]), true)
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: [:]), true, "no console key is no proof")
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: [key: "yes"]), true)
        XCTAssertEqual(ClaudeSignInRenewal.screenLocked(session: ["kCGSessionOnConsoleKey": true]), true,
                       "the constant's name is not the key")
    }

    // MARK: - The run

    private final class FakeChild: ClaudeSignInRenewalChild {
        var outputs: [Data] = []
        var exited = false
        /// Exits by itself then, whatever it was sent: the stop tests set it so
        /// none can hang.
        var exitsAt: TimeInterval = .infinity
        var exitsOnInterrupt = true
        /// Like Claude Code: its way out writes to the terminal, so it ends
        /// only once someone reads that.
        var exitsOnlyWhenRead = false
        private var exiting = false
        var finishes = 0
        /// When each SIGINT came, by the fake clock.
        var interruptTimes: [TimeInterval] = []
        var interrupts: Int { interruptTimes.count }
        var interruptedAt: TimeInterval? { interruptTimes.first }
        let clock: () -> TimeInterval
        init(clock: @escaping () -> TimeInterval) { self.clock = clock }
        func readAvailable(max: Int) -> Data {
            if exiting { exited = true }
            return outputs.isEmpty ? Data() : outputs.removeFirst()
        }
        var hasExited: Bool { exited || clock() >= exitsAt }
        func interrupt() {
            interruptTimes.append(clock())
            if exitsOnInterrupt {
                if exitsOnlyWhenRead { exiting = true } else { exited = true }
            }
        }
        func finish() { finishes += 1 }
    }

    private final class FakeClock {
        var now: TimeInterval = 0
    }

    private let baseline = Date(timeIntervalSince1970: 1_000_000)

    private func probes(
        _ clock: FakeClock,
        itemModified: @escaping () -> Date?,
        verify: @escaping () -> ClaudeSignInRenewalVerdict = { .stillExpired },
        stillAllowed: @escaping () -> Bool = { true },
        refreshLockHeld: @escaping () -> Bool = { false }
    ) -> ClaudeSignInRenewalProbes {
        ClaudeSignInRenewalProbes(
            itemModified: itemModified,
            verify: verify,
            stillAllowed: stillAllowed,
            refreshLockHeld: refreshLockHeld,
            clock: { clock.now },
            sleep: { clock.now += $0 }
        )
    }

    func test_run_rewrittenAndReadBack_isRenewed_andStopsOnceTheRefreshLockIsGone() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        var verifies = 0
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock,
            itemModified: { [baseline] in clock.now >= 2 ? baseline.addingTimeInterval(3) : baseline },
            verify: { verifies += 1; return .current },
            refreshLockHeld: { clock.now < 6 }
        ))
        XCTAssertEqual(result, .renewed)
        XCTAssertEqual(verifies, 1)
        XCTAssertEqual(child.interrupts, 1)
        XCTAssertGreaterThanOrEqual(child.interruptedAt ?? 0, 6, "stopped while Claude Code held its refresh lock")
        XCTAssertEqual(child.finishes, 1)
    }

    func test_run_aRewriteWithTheOldLogin_keepsWaitingForTheRenewal() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        var verifies = 0
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock,
            itemModified: { [baseline] in
                if clock.now >= 5 { return baseline.addingTimeInterval(9) }
                if clock.now >= 2 { return baseline.addingTimeInterval(3) }
                return baseline
            },
            verify: {
                verifies += 1
                return clock.now >= 5 ? .current : .stillExpired
            }
        ))
        XCTAssertEqual(result, .renewed)
        XCTAssertEqual(verifies, 2, "one look per rewrite")
    }

    func test_run_aRewriteThatNeedsADialogToRead_endsWithoutReadingIt() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock,
            itemModified: { [baseline] in clock.now >= 1 ? baseline.addingTimeInterval(3) : baseline },
            verify: { .notReadableQuietly }
        ))
        XCTAssertEqual(result, .rewrittenNotReadableQuietly)
        XCTAssertEqual(child.finishes, 1)
    }

    func test_run_aSignInScreen_endsAtOnce() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        child.outputs = [Data("Welcome".utf8), Data("\u{1b}[2KSelect login method:".utf8)]
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock, itemModified: { [baseline] in baseline }))
        XCTAssertEqual(result, .notRenewed(.stoppedAtScreen))
        XCTAssertLessThan(clock.now, 5)
        XCTAssertEqual(child.interrupts, 1)
    }

    func test_run_nothingHappens_endsAtTheDeadline_afterOneLastLook() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        var verifies = 0
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock, itemModified: { [baseline] in baseline }, verify: { verifies += 1; return .stillExpired }))
        XCTAssertEqual(result, .notRenewed(.deadline))
        XCTAssertEqual(verifies, 1)
        XCTAssertGreaterThanOrEqual(clock.now, ClaudeSignInRenewalRun.deadline)
        XCTAssertLessThan(clock.now, ClaudeSignInRenewalRun.deadline + 1)
    }

    func test_run_renewedInTheSameSecond_isFoundByTheLastLook() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock, itemModified: { [baseline] in baseline }, verify: { .current }))
        XCTAssertEqual(result, .renewed)
    }

    func test_run_claudeCodeExitingByItself_endsTheRun() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        child.exited = true
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock, itemModified: { [baseline] in baseline }))
        XCTAssertEqual(result, .notRenewed(.exited))
        XCTAssertEqual(child.interrupts, 0)
        XCTAssertEqual(child.finishes, 1)
    }

    func test_run_settingsChangingWhileItRuns_endsIt() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        let result = await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes(
            clock, itemModified: { [baseline] in baseline }, stillAllowed: { clock.now < 3 }))
        XCTAssertEqual(result, .notRenewed(.gatesChanged))
        XCTAssertLessThan(clock.now, 4)
    }

    /// The only signal is SIGINT, however long Claude Code takes; the stop
    /// lasts until it exits.
    func test_stop_aRefreshLockThatNeverGoes_onlySIGINT_untilItExits() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        child.exitsOnInterrupt = false
        child.exitsAt = 200
        await ClaudeSignInRenewalRun.stop(child, probes: probes(clock, itemModified: { nil }, refreshLockHeld: { true }))
        XCTAssertEqual(child.interrupts, 1, "asked again while Claude Code held its refresh lock")
        XCTAssertGreaterThanOrEqual(child.interruptedAt ?? 0, ClaudeSignInRenewalRun.refreshLockWait)
        XCTAssertGreaterThanOrEqual(clock.now, 200, "the stop ended while Claude Code still ran")
        XCTAssertEqual(child.finishes, 1)
    }

    func test_stop_aChildStillRunning_isAskedAgain_onlyBetweenRefreshes() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        child.exitsOnInterrupt = false
        child.exitsAt = 45
        // Claude Code takes the lock right after the first SIGINT and lets go at 20 s.
        await ClaudeSignInRenewalRun.stop(child, probes: probes(
            clock, itemModified: { nil }, refreshLockHeld: { child.interrupts > 0 && clock.now < 20 }))
        XCTAssertLessThan(child.interruptTimes.first ?? 99, 1)
        guard child.interrupts >= 2 else {
            return XCTFail("asked only once although Claude Code kept running: \(child.interruptTimes)")
        }
        XCTAssertGreaterThanOrEqual(child.interruptTimes[1], 20, "asked again while Claude Code held its refresh lock")
        for (earlier, later) in zip(child.interruptTimes, child.interruptTimes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later - earlier, ClaudeSignInRenewalRun.reinterruptInterval)
        }
        XCTAssertEqual(child.finishes, 1)
    }

    func test_stop_keepsReadingWhileClaudeCodeQuits() async {
        let clock = FakeClock()
        let child = FakeChild(clock: { clock.now })
        child.exitsOnlyWhenRead = true
        child.exitsAt = 100
        await ClaudeSignInRenewalRun.stop(child, probes: probes(clock, itemModified: { nil }))
        XCTAssertEqual(child.interrupts, 1)
        XCTAssertLessThan(clock.now, 5, "its output was not read, so it could not quit on SIGINT")
    }

    func test_quitWaitsLongerThanTheSIGINTWaitsForARefresh() {
        XCTAssertGreaterThan(ClaudeSignInRenewal.quitWait, ClaudeSignInRenewalRun.refreshLockWait)
    }

    // MARK: - The coordinator

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "test.claude-sign-in-renewal.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    override func tearDown() {
        for name in [suite!, "\(suite!).privacy", "\(suite!).switch"] {
            UserDefaults().removePersistentDomain(forName: name)
        }
        ClaudeSignInRenewal.shared.disable()
        ClaudeSignInRenewal.shared.environment = .live
        super.tearDown()
    }

    /// An environment where everything allows a renewal and `run` answers
    /// `result`.
    private func environment(
        now: Date = Date(timeIntervalSince1970: 5_000_000),
        result: ClaudeSignInRenewalRunResult = .renewed,
        runs: @escaping (ClaudeSignInRenewalRecord?) -> Void = { _ in }
    ) -> ClaudeSignInRenewal.Environment {
        var env = ClaudeSignInRenewal.Environment.live
        env.now = { now }
        env.isSandboxed = { false }
        env.allowedBySettings = { true }
        env.findClaudeBinary = { "/usr/local/bin/claude" }
        env.itemModified = { Date(timeIntervalSince1970: 4_000_000) }
        env.isScreenLocked = { false }
        env.verify = { _ in .stillExpired }
        env.acquireInstanceLock = { {} }
        env.refreshLockHeld = { false }
        env.clock = { 0 }
        env.sleep = { _ in }
        env.defaults = defaults
        env.run = { [defaults] _, _, _ in
            runs(defaults.map { d in
                ClaudeSignInRenewalRecord(
                    lastAttemptAt: (d.object(forKey: ClaudeSignInRenewal.lastAttemptKey) as? Double)
                        .map(Date.init(timeIntervalSince1970:)),
                    consecutiveFailures: d.integer(forKey: ClaudeSignInRenewal.failuresKey))
            })
            return result
        }
        return env
    }

    private func makeRenewal(_ env: ClaudeSignInRenewal.Environment, onRenewed: @escaping @Sendable () -> Void = {})
        -> ClaudeSignInRenewal
    {
        let renewal = ClaudeSignInRenewal(environment: env)
        renewal.enableInThisProcess(onRenewed: onRenewed)
        return renewal
    }

    func test_notEnabledInThisProcess_startsNothing() async {
        var ran = false
        let renewal = ClaudeSignInRenewal(environment: environment(runs: { _ in ran = true }))
        let outcome = await renewal.attemptIfAllowed(userAsked: true)
        XCTAssertEqual(outcome, .skipped(.notEnabledInThisProcess))
        XCTAssertFalse(ran)
    }

    func test_eachGate_startsNothing() async {
        typealias Change = (inout ClaudeSignInRenewal.Environment) -> Void
        let cases: [(ClaudeSignInRenewalSkip, Change)] = [
            (.sandboxed, { $0.isSandboxed = { true } }),
            (.notAllowedBySettings, { $0.allowedBySettings = { false } }),
            (.screenLocked, { $0.isScreenLocked = { true } }),
            (.screenLocked, { $0.isScreenLocked = { nil } }),
            (.itemDateUnreadable, { $0.itemModified = { nil } }),
            (.noClaudeBinary, { $0.findClaudeBinary = { nil } }),
            (.anotherInstance, { $0.acquireInstanceLock = { nil } }),
        ]
        for (skip, change) in cases {
            var ran = false
            var env = environment(runs: { _ in ran = true })
            change(&env)
            let outcome = await makeRenewal(env).attemptIfAllowed(userAsked: false)
            XCTAssertEqual(outcome, .skipped(skip))
            XCTAssertFalse(ran, "\(skip)")
            XCTAssertNil(defaults.object(forKey: ClaudeSignInRenewal.lastAttemptKey), "\(skip) counted as an attempt")
        }
    }

    func test_success_resetsTheFailures_recordsTheLogin_andRefreshesOnce() async {
        let now = Date(timeIntervalSince1970: 5_000_000)
        defaults.set(now.addingTimeInterval(-2 * 24 * 3600).timeIntervalSince1970, forKey: ClaudeSignInRenewal.lastAttemptKey)
        defaults.set(4, forKey: ClaudeSignInRenewal.failuresKey)
        var reservation: ClaudeSignInRenewalRecord?
        let refreshed = expectation(description: "refresh")
        let renewal = makeRenewal(environment(now: now, result: .renewed, runs: { reservation = $0 })) {
            refreshed.fulfill()
        }
        let outcome = await renewal.attemptIfAllowed(userAsked: false, expiredToken: "fp-expired")
        XCTAssertEqual(outcome, .ran(.renewed))
        await fulfillment(of: [refreshed], timeout: 1)
        XCTAssertEqual(reservation?.lastAttemptAt, now, "the attempt was not recorded before Claude Code started")
        XCTAssertEqual(reservation?.consecutiveFailures, 5)
        let record = renewal.load(renewal.environment)
        XCTAssertEqual(record.consecutiveFailures, 0)
        XCTAssertEqual(record.expiredLoginAtLastAttempt, "fp-expired")
    }

    func test_failure_countsUp_andCallsNoRefresh() async {
        let renewal = makeRenewal(environment(result: .notRenewed(.deadline))) {
            XCTFail("refreshed after a failed renewal")
        }
        let outcome = await renewal.attemptIfAllowed(userAsked: false)
        XCTAssertEqual(outcome, .ran(.notRenewed(.deadline)))
        XCTAssertEqual(renewal.load(renewal.environment).consecutiveFailures, 1)
        let again = await renewal.attemptIfAllowed(userAsked: false)
        XCTAssertEqual(again, .skipped(.backingOff))
    }

    /// Seen on 2026-11-24: Claude Code started by the Claude desktop app
    /// rewrote the item three times in 40 minutes and left the login as it
    /// was. A rewrite like that must not undo the backoff; a new login does.
    func test_aRewriteKeepingTheSameLogin_keepsTheBackoff_aNewLoginLiftsIt() async {
        let start = Date(timeIntervalSince1970: 5_000_000)
        let clock = LockedBox<Date>(start)
        let itemDate = LockedBox<Date?>(Date(timeIntervalSinceReferenceDate: 4_000_000))
        var env = environment(result: .notRenewed(.deadline))
        env.now = { clock.get() }
        env.itemModified = { itemDate.get() }
        let renewal = makeRenewal(env)
        for failure in 1...3 {
            let outcome = await renewal.attemptIfAllowed(userAsked: false, expiredToken: "fp-old")
            XCTAssertEqual(outcome, .ran(.notRenewed(.deadline)), "attempt \(failure)")
            clock.set(clock.get().addingTimeInterval(ClaudeSignInRenewalPolicy.interval(afterFailures: failure)))
        }
        // Three failures: the next is 2 h after the last. 31 minutes on, the
        // item rewritten with the same login is still held back.
        clock.set(clock.get().addingTimeInterval(-ClaudeSignInRenewalPolicy.interval(afterFailures: 3) + 31 * 60))
        itemDate.set(itemDate.get().addingTimeInterval(600))
        let sameLogin = await renewal.attemptIfAllowed(userAsked: false, expiredToken: "fp-old")
        XCTAssertEqual(sameLogin, .skipped(.backingOff))
        let newLogin = await renewal.attemptIfAllowed(userAsked: false, expiredToken: "fp-new")
        XCTAssertEqual(newLogin, .ran(.notRenewed(.deadline)))
        XCTAssertEqual(renewal.load(renewal.environment).expiredLoginAtLastAttempt, "fp-new")
    }

    func test_aRewriteThatCannotBeReadQuietly_refreshesNothing() async {
        let renewal = makeRenewal(environment(result: .rewrittenNotReadableQuietly)) {
            XCTFail("refreshed without a login read back")
        }
        let outcome = await renewal.attemptIfAllowed(userAsked: false)
        XCTAssertEqual(outcome, .ran(.rewrittenNotReadableQuietly))
    }

    func test_oneAtATime() async {
        let started = expectation(description: "started")
        var release: CheckedContinuation<Void, Never>?
        var env = environment()
        env.run = { _, _, _ in
            await withCheckedContinuation { continuation in
                release = continuation
                started.fulfill()
            }
            return .notRenewed(.deadline)
        }
        let renewal = makeRenewal(env)
        let first = Task { await renewal.attemptIfAllowed(userAsked: true) }
        await fulfillment(of: [started], timeout: 2)
        let second = await renewal.attemptIfAllowed(userAsked: true)
        XCTAssertEqual(second, .skipped(.alreadyRunning))
        release?.resume()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .ran(.notRenewed(.deadline)))
    }

    // MARK: - The read-back, through the real read

    private var now = Date(timeIntervalSinceReferenceDate: 3_000_000)
    private var itemDate: Date? = Date(timeIntervalSinceReferenceDate: 2_990_000)
    private var itemAnswer: (OSStatus, CFTypeRef?) = (errSecItemNotFound, nil)
    /// Each read of the item: whether it was told not to show the dialog.
    private var reads: [Bool] = []

    private func withFakeItem(_ body: () throws -> Void) rethrows {
        let cooldownSuite = "test.claude-sign-in-renewal.cooldown.\(UUID().uuidString)"
        let originalItemModified = ClaudeCredentials.keychainItemModified
        let originalCopy = ClaudeCredentials.copyKeychainItem
        ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: cooldownSuite)!
        ClaudeCredentials.nowProvider = { [unowned self] in self.now }
        ClaudeCredentials.clearKeychainReadCooldown()
        ClaudeCredentials.clearCachedKeychainCredentials()
        ClaudeCredentials.keychainItemModified = { [unowned self] in self.itemDate }
        ClaudeCredentials.copyKeychainItem = { [unowned self] query in
            let dict = query as NSDictionary
            self.reads.append(
                (dict[kSecUseAuthenticationUI as String] as? String) == (kSecUseAuthenticationUIFail as String))
            return self.itemAnswer
        }
        defer {
            ClaudeCredentials.clearCachedKeychainCredentials()
            ClaudeCredentials.copyKeychainItem = originalCopy
            ClaudeCredentials.keychainItemModified = originalItemModified
            ClaudeCredentials.nowProvider = { Date() }
            ClaudeCredentials.cooldownDefaults = UserDefaults(suiteName: "group.yyh.CLI-Pulse") ?? .standard
            UserDefaults().removePersistentDomain(forName: cooldownSuite)
        }
        try body()
    }

    private func item(_ token: String, expiresIn: TimeInterval) -> (OSStatus, CFTypeRef?) {
        let ms = Int64(now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
        let json = #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":\#(ms)}}"#
        return (errSecSuccess, Data(json.utf8) as CFData)
    }

    private func privacy(skip: Bool = false) -> PrivacySettings {
        let privacy = PrivacySettings(defaults: UserDefaults(suiteName: "\(suite!).privacy")!)
        privacy.skipClaudeKeychain = skip
        return privacy
    }

    /// The case the dialog is for in a collection's read: an expired copy of
    /// a rewritten item. The renewal's read must not show it.
    func test_readBack_ofAnExpiredCopyOfARewrittenItem_isQuiet_andKeepsTheNewLogin() {
        withFakeItem {
            itemAnswer = item("old", expiresIn: -60)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: privacy()))
            reads = []
            itemDate = itemDate!.addingTimeInterval(10)
            itemAnswer = item("new", expiresIn: 8 * 3600)

            let creds = ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy())
            XCTAssertEqual(creds?.accessToken, "new")
            XCTAssertEqual(reads, [true], "the read-back may show macOS's dialog")
            reads = []
            XCTAssertEqual(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: privacy())?.accessToken, "new")
            XCTAssertEqual(reads, [], "the copy taken by the read-back was not kept with its date")
        }
    }

    /// Claude Code rewrote the item within the same second as the date the
    /// app's copy was kept with: the read-back reads it all the same.
    func test_readBack_ofAnItemWithAnUnchangedDate_stillReadsIt() {
        withFakeItem {
            itemAnswer = item("old", expiresIn: -60)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: privacy()))
            reads = []
            itemAnswer = item("new", expiresIn: 8 * 3600)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: privacy()),
                         "control: a collection's read does not look again at an unchanged item")
            XCTAssertEqual(reads, [])
            XCTAssertEqual(ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy())?.accessToken, "new")
            XCTAssertEqual(reads, [true])
        }
    }

    func test_readBack_thatWouldNeedTheDialog_armsNoCooldown() {
        withFakeItem {
            itemAnswer = (errSecInteractionNotAllowed, nil)
            let log = ClaudeKeychainReadLog()
            let creds = ClaudeKeychainReadLog.$current.withValue(log) {
                ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy())
            }
            XCTAssertNil(creds)
            XCTAssertEqual(reads, [true])
            XCTAssertNil(ClaudeCredentials.activeKeychainReadCooldown())
            XCTAssertEqual(ClaudeSignInRenewal.verdict(creds: creds, miss: log.miss, now: now), .notReadableQuietly)
        }
    }

    func test_readBack_andTheItemsDate_followTheSwitches() {
        withFakeItem {
            itemAnswer = item("new", expiresIn: 8 * 3600)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy(skip: true)))
            XCTAssertNil(ClaudeCredentials.keychainItemModifiedIfAllowed(privacy: privacy(skip: true)))
            XCTAssertEqual(reads, [])
            XCTAssertEqual(ClaudeCredentials.keychainItemModifiedIfAllowed(privacy: privacy()), itemDate)
        }
    }

    /// A collection's read that finds the login expired starts a renewal (in
    /// the app, once enabled); the renewal's own read-back does not.
    /// A collection's read that finds the login expired starts a renewal (in
    /// the app, once enabled), and hands it the expired token's fingerprint,
    /// taken there and then, not later from a copy another read may replace.
    func test_anExpiredLogin_inACollectionsRead_startsARenewal_withThatTokensFingerprint() {
        withFakeItem {
            var env = environment()
            let checked = expectation(description: "read back")
            checked.assertForOverFulfill = false
            var excluded: String??
            env.run = { _, _, probes in
                _ = probes.verify()
                return .notRenewed(.deadline)
            }
            env.verify = { fingerprint in
                excluded = .some(fingerprint)
                checked.fulfill()
                return .stillExpired
            }
            ClaudeSignInRenewal.shared.environment = env
            ClaudeSignInRenewal.shared.enableInThisProcess {}

            itemAnswer = item("old", expiresIn: -60)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsIfAllowed(privacy: privacy()))
            wait(for: [checked], timeout: 2)
            XCTAssertEqual(excluded, .some(ClaudeOAuthBackoffState.fingerprint(forToken: "old")))
        }
    }

    func test_theReadBack_neverStartsARenewal() {
        withFakeItem {
            var env = environment()
            let started = expectation(description: "renewal asked")
            started.isInverted = true
            env.isSandboxed = {
                started.fulfill()
                return true
            }
            ClaudeSignInRenewal.shared.environment = env
            ClaudeSignInRenewal.shared.enableInThisProcess {}

            itemAnswer = item("old", expiresIn: -60)
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy()))
            XCTAssertNil(ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed(privacy: privacy()))
            wait(for: [started], timeout: 0.5)
        }
    }

    // MARK: - The switch

    func test_theSwitch_isOffUntilTurnedOn_andNeedsTheKeychainSwitchesToAllow() {
        let privacy = PrivacySettings(defaults: UserDefaults(suiteName: "\(suite!).switch")!)
        XCTAssertFalse(privacy.renewClaudeCodeSignIn)
        XCTAssertFalse(privacy.renewsClaudeCodeSignIn)
        privacy.renewClaudeCodeSignIn = true
        XCTAssertTrue(privacy.renewsClaudeCodeSignIn)
        privacy.skipClaudeKeychain = true
        XCTAssertFalse(privacy.renewsClaudeCodeSignIn)
        privacy.skipClaudeKeychain = false
        privacy.localOnlyMode = true
        XCTAssertFalse(privacy.renewsClaudeCodeSignIn)
        XCTAssertTrue(PrivacySettings(defaults: UserDefaults(suiteName: "\(suite!).switch")!).renewClaudeCodeSignIn,
                      "the switch was not kept")
    }

    // MARK: - The build

    func test_offeredOnlyInTheDeveloperIDBuild() {
        #if DEVID_BUILD
        XCTAssertEqual(ClaudeSignInRenewal.isOfferedInThisBuild, !MASSandboxGate.isSandboxed)
        #else
        XCTAssertFalse(ClaudeSignInRenewal.isOfferedInThisBuild)
        XCTAssertFalse(ClaudeSignInRenewal.enableForThisApp(allowsLiveCollection: true) {})
        #endif
        XCTAssertFalse(ClaudeSignInRenewal.enableForThisApp(allowsLiveCollection: false) {},
                       "a QA or quarantined runtime turned it on")
    }

    /// Quitting while Claude Code runs: the quit waits while the attempt
    /// stops it its usual way (SIGINT, output read until it exits).
    func test_quitting_duringARun_waitsForClaudeCodeToStop() async {
        let child = FakeChild(clock: { ProcessInfo.processInfo.systemUptime })
        child.exitsOnlyWhenRead = true
        // A failure ends the test (the quit returns early), not hangs it.
        child.exitsAt = ProcessInfo.processInfo.systemUptime + 15
        let running = expectation(description: "running")
        var env = environment()
        env.clock = { ProcessInfo.processInfo.systemUptime }
        env.sleep = { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        env.run = { _, baseline, probes in
            running.fulfill()
            return await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes)
        }
        let renewal = makeRenewal(env)
        let attempt = Task { await renewal.attemptIfAllowed(userAsked: false) }
        await fulfillment(of: [running], timeout: 2)
        // On a thread of its own, as the app's main thread would be: the quit
        // blocks while the attempt, on the concurrency pool, stops Claude Code.
        let quitReturned = expectation(description: "quit returned")
        DispatchQueue.global().async {
            renewal.appWillTerminate()
            quitReturned.fulfill()
        }
        await fulfillment(of: [quitReturned], timeout: 10)
        XCTAssertEqual(child.interrupts, 1, "quit returned before Claude Code was asked to stop")
        XCTAssertEqual(child.finishes, 1, "quit returned before Claude Code was stopped")
        let outcome = await attempt.value
        XCTAssertEqual(outcome, .ran(.notRenewed(.gatesChanged)))
    }

    func test_quitting_startsNoMore() async {
        let renewal = makeRenewal(environment())
        renewal.appWillTerminate()
        let outcome = await renewal.attemptIfAllowed(userAsked: true)
        XCTAssertEqual(outcome, .skipped(.notEnabledInThisProcess))
    }

    // MARK: - The command

    #if DEVID_BUILD
    func test_theCommandLine() {
        let args = ClaudeSignInRenewalProcess.launchArguments
        XCTAssertTrue(args.contains("--safe-mode"))
        XCTAssertFalse(args.contains("--bare"), "bare mode never reads the claude.ai login")
        XCTAssertFalse(args.contains("-p") || args.contains("--print"), "a prompt would be a model request")
        let tools = try? XCTUnwrap(args.firstIndex(of: "--tools"))
        XCTAssertEqual(tools.map { args[$0 + 1] }, "")
        let settingsIndex = try? XCTUnwrap(args.firstIndex(of: "--settings"))
        let settings = settingsIndex.flatMap {
            try? JSONSerialization.jsonObject(with: Data(args[$0 + 1].utf8)) as? [String: Bool]
        }
        XCTAssertEqual(settings, ["remoteControlAtStartup": false, "disableAllHooks": true])
    }

    func test_theEnvironment_signsInWithTheWatchedItem_andKeepsTheUsersRestrictions() {
        let env = ClaudeSignInRenewalProcess.launchEnvironment(base: [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "ANTHROPIC_API_KEY": "x",
            "ANTHROPIC_BASE_URL": "x",
            "CLAUDE_CODE_OAUTH_TOKEN": "x",
            "CLAUDE_CONFIG_DIR": "/elsewhere",
            "CLAUDE_SECURESTORAGE_CONFIG_DIR": "/elsewhere",
            "CLAUDE_CODE_USE_BEDROCK": "1",
            "CLAUDE_CODE_SIMPLE": "1",
            "CLAUDE_CODE_ENTRYPOINT": "x",
            "CLAUDECODE": "1",
            "CLAUDE_CODE_CHILD_SESSION": "1",
            "CLAUDE_PID": "1",
            "CODEXBAR_ANYTHING": "x",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1",
        ], workingDirectory: "/tmp/w")
        XCTAssertEqual(env, [
            "PATH": "/usr/bin",
            "HOME": "/Users/me",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
            "DISABLE_TELEMETRY": "1",
            "DISABLE_AUTOUPDATER": "1",
            "PWD": "/tmp/w",
            "TERM": "xterm-256color",
        ])
    }
    #endif

    // MARK: - Claude Code's refresh lock

    func test_refreshLock_heldOnlyWhileFresh() throws {
        let home = NSTemporaryDirectory() + "claude-sign-in-renewal-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let lock = home + "/.claude/.oauth_refresh.lock"
        let now = Date()
        XCTAssertFalse(ClaudeSignInRenewal.refreshLockHeld(home: home, now: now))
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)], ofItemAtPath: lock)
        XCTAssertTrue(ClaudeSignInRenewal.refreshLockHeld(home: home, now: now))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: lock)
        XCTAssertFalse(ClaudeSignInRenewal.refreshLockHeld(home: home, now: now), "a stale lock is no refresh")
        try FileManager.default.createDirectory(atPath: home + "/.claude.lock", withIntermediateDirectories: true)
        XCTAssertTrue(ClaudeSignInRenewal.refreshLockHeld(home: home, now: Date()), "the older lock counts too")
    }
}
#endif
