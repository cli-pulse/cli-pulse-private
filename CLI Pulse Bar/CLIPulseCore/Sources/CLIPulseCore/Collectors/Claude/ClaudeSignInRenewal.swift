#if os(macOS)
import AppKit
import CoreGraphics
import Darwin
import Foundation
import os

// 2026-11-24: let Claude Code renew its own expired sign-in.
//
// CLI Pulse reads Claude usage with the OAuth token in Claude Code's keychain
// item. Only the Claude Code CLI renews that login. Someone who runs Claude
// Code only from the Claude desktop app never runs the CLI: the desktop app's
// sessions are signed in by the app, not by that item. So the login expired,
// and the Claude card said "Not signed in" until the user ran `claude` by
// hand. On the owner's Mac on 2026-11-23, `expiresAt` was 13 h in the past.
//
// With Settings › Privacy › "Renew Claude Code's sign-in" on (Developer ID
// build, off by default), the app starts Claude Code itself, as the user
// would, and lets it renew the login. It starts interactively and nothing is
// typed. Claude Code 2.1.330 sends its startup requests with the stored login.
// It refreshes an expired one first (or on the 401), under its own
// cross-process lock, and writes the renewed login back to the item. No
// prompt is sent, so there is no model request. CLI Pulse never uses the
// refresh token itself: that rotates it and can sign Claude Code out.
//
// Modelled on CodexBar's `ClaudeOAuthDelegatedRefreshCoordinator`, which does
// this only when the user clicks Refresh. Here it also runs on its own, with
// these guards:
// - `--safe-mode`: none of the user's plugins, hooks or MCP servers start.
// - Nothing is ever typed. A sign-in, trust or MCP screen ends the run.
// - Only while the screen is unlocked and the item's attributes can be read
//   without a dialog: a locked keychain fails that read.
// - Success is a token read back without a dialog, not merely a rewrite.
// - Claude Code is never stopped while it holds its refresh lock.
// - Backoff: 30 min after any attempt, doubling after each failure up to a
//   day.

/// Why a renewal did not start.
enum ClaudeSignInRenewalSkip: Equatable, Sendable {
    /// Only the app turns renewal on (`enableInThisProcess`). The LoginItem
    /// helper picks up a renewed login by itself, through the item's date.
    case notEnabledInThisProcess
    /// The App Store build cannot start another app's command-line tool.
    case sandboxed
    /// Settings › Privacy: the switch is off, or Strict privacy mode or
    /// "Skip Claude Code keychain access" is on.
    case notAllowedBySettings
    case backingOff
    /// A locked login keychain could make Claude Code's own keychain call
    /// show a password dialog. Not counted as an attempt.
    case screenLocked
    case noClaudeBinary
    /// The item's attributes could not be read without a dialog: no item, or
    /// a locked keychain. Without its date a renewal cannot be seen either.
    case itemDateUnreadable
    case alreadyRunning
    /// Another copy of the app holds the renewal lock.
    case anotherInstance
}

/// What the throttle remembers between attempts, kept in the app's defaults.
struct ClaudeSignInRenewalRecord: Equatable, Sendable {
    var lastAttemptAt: Date?
    /// Attempts in a row that did not renew the login.
    var consecutiveFailures: Int = 0
    /// The item's date (whole seconds) when the last attempt ended. A
    /// different date later means something else rewrote the item, for
    /// example the user signed in again.
    var itemDateAfterLastAttempt: Int?
}

/// When the next renewal may start.
enum ClaudeSignInRenewalPolicy {
    /// After any attempt. A renewed login lasts hours, so after a success
    /// this only bounds a loop.
    static let firstInterval: TimeInterval = 30 * 60
    static let longestInterval: TimeInterval = 24 * 60 * 60
    /// A Refresh the user clicked starts one regardless of the backoff, but
    /// not twice within this.
    static let userAskedFloor: TimeInterval = 60

    /// After `failures` attempts in a row that renewed nothing: 30 min, then
    /// 30 min, 1 h, 2 h, 4 h, 8 h, 16 h, and a day from then on. A login that
    /// cannot be renewed (signed out elsewhere, offline, Claude Code's
    /// nonessential traffic turned off) costs one start a day.
    static func interval(afterFailures failures: Int) -> TimeInterval {
        guard failures > 1 else { return firstInterval }
        let doublings = Double(min(failures - 1, 16))
        return min(firstInterval * pow(2, doublings), longestInterval)
    }

    /// - Parameter itemDate: the item's date now, whole seconds.
    static func allows(
        now: Date, record: ClaudeSignInRenewalRecord, userAsked: Bool, itemDate: Int?
    ) -> Bool {
        guard let last = record.lastAttemptAt else { return true }
        let since = now.timeIntervalSince(last)
        // A clock set back leaves the last attempt in the future: count again
        // from now rather than wait for the clock to catch up.
        if since < 0 { return true }
        if userAsked { return since >= userAskedFloor }
        if since < firstInterval { return false }
        // Rewritten by something else since the last attempt ended (the user
        // signed in again, say): a new login, so the old failures don't count.
        if let itemDate, let recorded = record.itemDateAfterLastAttempt, itemDate != recorded {
            return true
        }
        return since >= interval(afterFailures: record.consecutiveFailures)
    }
}

/// What Claude Code's screen says about the run.
///
/// Nothing is ever typed. Enter on a screen the renewal did not expect
/// confirms that screen's default, and on the sign-in screen that starts a
/// browser sign-in. So any screen that wants an answer ends the run.
enum ClaudeSignInRenewalScreen {
    /// How much of the latest output is looked at. Older output is gone from
    /// the screen; matching it would act on a screen no longer there.
    static let windowBytes = 8 * 1024

    /// Lowercased. The renewal failed, or Claude Code waits for a choice: a
    /// sign-in, the folder-trust question (it should not come up in the
    /// renewal's empty folder), or an MCP server approval.
    static let stopNeedles: [String] = [
        "select login method",
        "please run /login",
        "not logged in",
        "sign in again",
        "invalid api key",
        "oauth token has expired",
        "quick safety check",
        "yes, i trust this folder",
        "do you trust the files in this folder",
    ] + ClaudeCLIPTYStrategy.mcpApprovalNeedles

    /// - Parameter normalized: the latest output, ANSI stripped, lowercased.
    ///   Compared with and without whitespace: a terminal UI that places text
    ///   by cursor position can leave the words of a line run together once
    ///   the escape codes are gone.
    static func shouldStop(_ normalized: String) -> Bool {
        let compact = withoutWhitespace(normalized)
        return stopNeedles.contains { normalized.contains($0) || compact.contains(withoutWhitespace($0)) }
    }

    private static func withoutWhitespace(_ text: String) -> String {
        String(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
    }

    /// `window` with `chunk` appended, cut to the last `windowBytes`.
    static func appending(_ chunk: Data, to window: Data) -> Data {
        var next = window
        next.append(chunk)
        if next.count > windowBytes { next = next.suffix(windowBytes) }
        return next
    }

    static func normalized(_ window: Data) -> String {
        ClaudeCredentials.stripANSI(String(decoding: window, as: UTF8.self)).lowercased()
    }
}

/// What the item holds after Claude Code rewrote it, read without a dialog.
enum ClaudeSignInRenewalVerdict: Equatable, Sendable {
    /// A login that lasts beyond the next few minutes.
    case current
    /// Still the expired one, or one about to expire.
    case stillExpired
    /// Could not be read without a dialog, or a Settings › Privacy switch
    /// now says not to read it.
    case notReadableQuietly
}

/// How one start of Claude Code ended.
enum ClaudeSignInRenewalRunResult: Equatable, Sendable {
    case renewed
    /// Rewritten, but reading it back would need a dialog. The next scheduled
    /// refresh reads it as it does after the user runs `claude`.
    case rewrittenNotReadableQuietly
    case notRenewed(Reason)

    enum Reason: Equatable, Sendable {
        case deadline
        case exited
        case stoppedAtScreen
        /// Settings changed or the screen locked while it ran.
        case gatesChanged
        case launchFailed
    }
}

/// The started Claude Code, as the run sees it. Tests pass a fake.
protocol ClaudeSignInRenewalChild: AnyObject {
    /// Output available now, at most `max` bytes. Never blocks.
    func readAvailable(max: Int) -> Data
    /// True once the process has exited (not yet reaped).
    var hasExited: Bool { get }
    /// SIGINT: how Claude Code is quit from any screen, as Ctrl-C would. Its
    /// own way out, which waits for a refresh in flight and removes its
    /// session record. The only signal it is ever sent while it runs.
    func interrupt()
    /// After it exited: ends anything it left in its process group, and reaps
    /// it. Called once, last.
    func finish()
}

/// What the run asks the system while Claude Code runs.
struct ClaudeSignInRenewalProbes: @unchecked Sendable {
    var itemModified: () -> Date?
    var verify: () -> ClaudeSignInRenewalVerdict
    /// Settings still allow it and the screen is still unlocked.
    var stillAllowed: () -> Bool
    /// Claude Code is between asking for a new token and storing it.
    var refreshLockHeld: () -> Bool
    /// Monotonic seconds.
    var clock: () -> TimeInterval
    var sleep: (TimeInterval) async -> Void
}

/// The loop around one start: watch, verify, stop.
enum ClaudeSignInRenewalRun {
    static let deadline: TimeInterval = 30
    static let pollInterval: TimeInterval = 0.5
    /// How long a refresh in progress holds back the SIGINT.
    static let refreshLockWait: TimeInterval = 30
    /// A Claude Code still running this long after the last SIGINT, with no
    /// refresh in progress, is sent another.
    static let reinterruptInterval: TimeInterval = 10

    static func drive(
        _ child: ClaudeSignInRenewalChild, baseline: Date, probes: ClaudeSignInRenewalProbes
    ) async -> ClaudeSignInRenewalRunResult {
        let result = await watch(child, baseline: baseline, probes: probes)
        await stop(child, probes: probes)
        return result
    }

    private static func watch(
        _ child: ClaudeSignInRenewalChild, baseline: Date, probes: ClaudeSignInRenewalProbes
    ) async -> ClaudeSignInRenewalRunResult {
        let start = probes.clock()
        var window = Data()
        var watchedDate = wholeSeconds(baseline)
        var nextPoll = start

        func finalLook(_ otherwise: ClaudeSignInRenewalRunResult.Reason) -> ClaudeSignInRenewalRunResult {
            // Another writer may have renewed it, or Claude Code wrote it in
            // the same second as the baseline.
            switch probes.verify() {
            case .current: return .renewed
            case .stillExpired, .notReadableQuietly: return .notRenewed(otherwise)
            }
        }

        while true {
            let chunk = child.readAvailable(max: 64 * 1024)
            if !chunk.isEmpty {
                window = ClaudeSignInRenewalScreen.appending(chunk, to: window)
                if ClaudeSignInRenewalScreen.shouldStop(ClaudeSignInRenewalScreen.normalized(window)) {
                    return .notRenewed(.stoppedAtScreen)
                }
            }
            if !probes.stillAllowed() { return .notRenewed(.gatesChanged) }
            let now = probes.clock()
            if now >= nextPoll {
                nextPoll = now + pollInterval
                if let date = probes.itemModified(), wholeSeconds(date) != watchedDate {
                    switch probes.verify() {
                    case .current:
                        return .renewed
                    case .notReadableQuietly:
                        return .rewrittenNotReadableQuietly
                    case .stillExpired:
                        // Rewritten with the old login (seen on 2026-11-23);
                        // keep waiting for the renewal.
                        watchedDate = wholeSeconds(date)
                    }
                }
            }
            if child.hasExited { return finalLook(.exited) }
            if probes.clock() - start >= deadline { return finalLook(.deadline) }
            await probes.sleep(0.1)
        }
    }

    /// Stopping Claude Code between receiving a new token and storing it
    /// could lose the rotated refresh token and sign it out, so it is only
    /// ever asked to quit (SIGINT), never killed. Its own way out waits for a
    /// refresh in flight (2 s in 2.1.330: "OAuth refresh still in flight
    /// after …ms; exiting without waiting further"), so the SIGINT waits
    /// first for a refresh in progress to end (up to `refreshLockWait`). If it
    /// keeps running, it is asked again, never while a refresh is in progress,
    /// and its output is read all along (its way out writes to the terminal),
    /// until it exits: the attempt, with its claim and the instance lock,
    /// lasts until then.
    static func stop(_ child: ClaudeSignInRenewalChild, probes: ClaudeSignInRenewalProbes) async {
        await waitWhileRefreshing(child, seconds: refreshLockWait, probes: probes)
        let start = probes.clock()
        var lastInterrupt: TimeInterval?
        while !child.hasExited {
            let now = probes.clock()
            if lastInterrupt == nil
                || (now - lastInterrupt! >= reinterruptInterval && !probes.refreshLockHeld()) {
                child.interrupt()
                lastInterrupt = now
            }
            // Quick at first; once a minute has gone by, at a calmer pace.
            await pause(child, now - start < 60 ? 0.1 : 1, probes: probes)
        }
        child.finish()
    }

    private static func waitWhileRefreshing(
        _ child: ClaudeSignInRenewalChild, seconds: TimeInterval, probes: ClaudeSignInRenewalProbes
    ) async {
        let until = probes.clock() + seconds
        while !child.hasExited, probes.refreshLockHeld(), probes.clock() < until {
            await pause(child, 0.25, probes: probes)
        }
    }

    /// Waits, reading what Claude Code prints meanwhile. Its way out writes
    /// to the terminal; with nobody reading, the pseudo-terminal fills and it
    /// blocks there and never exits (measured 2026-11-24: SIGINT and SIGTERM
    /// both seemed ignored until the output was read).
    private static func pause(
        _ child: ClaudeSignInRenewalChild, _ seconds: TimeInterval, probes: ClaudeSignInRenewalProbes
    ) async {
        _ = child.readAvailable(max: 64 * 1024)
        await probes.sleep(seconds)
    }

    static func wholeSeconds(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970.rounded())
    }
}

/// Starts Claude Code so it renews its own expired sign-in. The app only.
public final class ClaudeSignInRenewal: @unchecked Sendable {
    public static let shared = ClaudeSignInRenewal()

    enum Outcome: Equatable, Sendable {
        case skipped(ClaudeSignInRenewalSkip)
        case ran(ClaudeSignInRenewalRunResult)
    }

    /// Everything the renewal asks the system. Tests replace it.
    struct Environment: @unchecked Sendable {
        var now: () -> Date
        var isSandboxed: () -> Bool
        /// Settings › Privacy, as this process follows them.
        var allowedBySettings: () -> Bool
        var findClaudeBinary: () -> String?
        /// The item's modification date: attributes only, no dialog, and
        /// only when Settings › Privacy allow reading the item.
        var itemModified: () -> Date?
        /// nil when it cannot be told; treated as locked.
        var isScreenLocked: () -> Bool?
        /// The item read back without a dialog; the argument is the expired
        /// token's fingerprint, not to count as renewed.
        var verify: (_ excluding: String?) -> ClaudeSignInRenewalVerdict
        /// Held for the whole attempt against a second copy of the app; nil
        /// when another holds it. Calling the returned closure releases it.
        var acquireInstanceLock: () -> (() -> Void)?
        /// Starts Claude Code and drives it to an end.
        var run: (_ binary: String, _ baseline: Date, _ probes: ClaudeSignInRenewalProbes) async
            -> ClaudeSignInRenewalRunResult
        var refreshLockHeld: () -> Bool
        var clock: () -> TimeInterval
        var sleep: (TimeInterval) async -> Void
        var defaults: UserDefaults

        static var live: Environment {
            Environment(
                now: { Date() },
                isSandboxed: { MASSandboxGate.isSandboxed },
                allowedBySettings: { PrivacySettings.shared.renewsClaudeCodeSignIn },
                findClaudeBinary: { ClaudeCLIPTYStrategy.findClaudeBinary() },
                itemModified: { ClaudeCredentials.keychainItemModifiedIfAllowed() },
                isScreenLocked: { ClaudeSignInRenewal.liveScreenLocked() },
                verify: { ClaudeSignInRenewal.liveVerify(excluding: $0) },
                acquireInstanceLock: { ClaudeSignInRenewal.liveInstanceLock() },
                run: { binary, baseline, probes in
                    #if DEVID_BUILD
                    // The app may have begun to quit since the gates.
                    guard probes.stillAllowed() else { return .notRenewed(.gatesChanged) }
                    guard let child = ClaudeSignInRenewalProcess.spawn(binary: binary) else {
                        return .notRenewed(.launchFailed)
                    }
                    return await ClaudeSignInRenewalRun.drive(child, baseline: baseline, probes: probes)
                    #else
                    return .notRenewed(.launchFailed)
                    #endif
                },
                refreshLockHeld: { ClaudeSignInRenewal.liveRefreshLockHeld() },
                clock: { ProcessInfo.processInfo.systemUptime },
                sleep: { seconds in try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
                defaults: .standard
            )
        }
    }

    // `cli_pulse_`: inside UnsandboxedDataMigration's allowlist of the app's
    // own standard-defaults keys.
    static let lastAttemptKey = "cli_pulse_claude_sign_in_renewal_last_attempt"
    static let failuresKey = "cli_pulse_claude_sign_in_renewal_failures"
    static let itemDateKey = "cli_pulse_claude_sign_in_renewal_item_date"

    private static let logger = Logger(subsystem: "com.clipulse", category: "ClaudeSignInRenewal")

    private let lock = NSLock()
    private var enabled = false
    private var running = false
    private var onRenewed: (@Sendable () -> Void)?
    /// Signalled when the running attempt has stopped Claude Code.
    private var runStopped: DispatchSemaphore?
    private var terminationObserver: NSObjectProtocol?
    private var _environment: Environment

    init(environment: Environment = .live) {
        _environment = environment
    }

    var environment: Environment {
        get { lock.withLock { _environment } }
        set { lock.withLock { _environment = newValue } }
    }

    /// Whether this build offers the renewal: the Developer ID build, and
    /// not sandboxed (an App Store build cannot start another app's
    /// program). Settings shows the switch only then.
    public static var isOfferedInThisBuild: Bool {
        #if DEVID_BUILD
        return !MASSandboxGate.isSandboxed
        #else
        return false
        #endif
    }

    /// The app's launch. Turns the renewal on where this build offers it and
    /// the runtime collects live (a QA or quarantined runtime starts
    /// nothing). Called unconditionally, so CI's App Store build compiles the
    /// call; it does nothing there. Returns whether it turned it on.
    @discardableResult
    public static func enableForThisApp(
        allowsLiveCollection: Bool, onRenewed: @escaping @Sendable () -> Void
    ) -> Bool {
        guard allowsLiveCollection, isOfferedInThisBuild else { return false }
        shared.enableInThisProcess(onRenewed: onRenewed)
        return true
    }

    /// From now on an expired login read in this process may start a
    /// renewal, as Settings › Privacy allow. `onRenewed` runs after one
    /// renewed the login, so the app can refresh and the card shows it at
    /// once.
    func enableInThisProcess(onRenewed: @escaping @Sendable () -> Void) {
        lock.withLock {
            enabled = true
            self.onRenewed = onRenewed
            if terminationObserver == nil {
                terminationObserver = NotificationCenter.default.addObserver(
                    forName: NSApplication.willTerminateNotification, object: nil, queue: nil
                ) { [weak self] _ in self?.appWillTerminate() }
            }
        }
    }

    /// How long quitting the app waits for a running attempt to stop Claude
    /// Code: past the SIGINT's own wait for a refresh in progress.
    static let quitWait: TimeInterval = ClaudeSignInRenewalRun.refreshLockWait + 10

    /// The app is quitting: start no more, and hold the quit (on the main
    /// thread, at most `quitWait`) while a running attempt stops Claude Code
    /// its usual way: it sees the switch-off within a tenth of a second, then
    /// SIGINT, reading its output, the refresh lock respected. Normally that
    /// takes under a second. If the wait runs out, Claude Code keeps what it
    /// was told; once the app is gone its terminal writes fail rather than
    /// block, and launchd reaps it.
    func appWillTerminate() {
        let stopped: DispatchSemaphore? = lock.withLock {
            enabled = false
            return runStopped
        }
        _ = stopped?.wait(timeout: .now() + Self.quitWait)
    }

    /// For tests.
    func disable() {
        lock.withLock {
            enabled = false
            onRenewed = nil
        }
    }

    /// `ClaudeCredentials.readKeychainCredentials` found the login in the item
    /// expired. Returns at once; a renewal, if one starts, runs detached, so
    /// no collection waits for it. A Refresh the user clicked
    /// (`RefreshInteraction.userInitiated`, read here, before detaching) is
    /// not held back by the backoff.
    /// - Parameter expiredToken: the expired access token's fingerprint, taken
    ///   where it was read: a token read back with it was not renewed,
    ///   whatever its expiry says.
    func expiredLoginSeen(expiredToken: String) {
        guard lock.withLock({ enabled }) else { return }
        let userAsked = RefreshInteraction.current == .userInitiated
        Task.detached(priority: .utility) { [self] in
            _ = await attemptIfAllowed(userAsked: userAsked, expiredToken: expiredToken)
        }
    }

    /// One renewal, if everything allows it.
    func attemptIfAllowed(userAsked: Bool, expiredToken: String? = nil) async -> Outcome {
        let claim: ClaudeSignInRenewalSkip? = lock.withLock {
            guard enabled else { return .notEnabledInThisProcess }
            guard !running else { return .alreadyRunning }
            running = true
            return nil
        }
        if let claim { return .skipped(claim) }
        defer { lock.withLock { running = false } }

        let env = environment
        if let skip = gate(env, userAsked: userAsked) {
            if skip != .backingOff {
                Self.logger.info("Claude sign-in renewal not started: \(String(describing: skip), privacy: .public)")
            }
            return .skipped(skip)
        }
        guard let binary = env.findClaudeBinary() else { return .skipped(.noClaudeBinary) }
        guard let baseline = env.itemModified() else { return .skipped(.itemDateUnreadable) }
        guard let releaseInstanceLock = env.acquireInstanceLock() else { return .skipped(.anotherInstance) }
        defer { releaseInstanceLock() }

        // Recorded before the start, as a failure, so a start that hangs or
        // a crash still holds the next one back.
        var record = load(env)
        record.lastAttemptAt = env.now()
        record.consecutiveFailures += 1
        save(record, env)

        Self.logger.info("Claude sign-in renewal: starting Claude Code")
        let probes = ClaudeSignInRenewalProbes(
            itemModified: env.itemModified,
            verify: { env.verify(expiredToken) },
            stillAllowed: { [self] in
                lock.withLock { enabled } && env.allowedBySettings() && !(env.isScreenLocked() ?? true)
            },
            refreshLockHeld: env.refreshLockHeld,
            clock: env.clock,
            sleep: env.sleep
        )
        let stopped = DispatchSemaphore(value: 0)
        lock.withLock { runStopped = stopped }
        let result = await env.run(binary, baseline, probes)
        lock.withLock { runStopped = nil }
        stopped.signal()

        if result == .renewed { record.consecutiveFailures = 0 }
        record.itemDateAfterLastAttempt = env.itemModified().map(ClaudeSignInRenewalRun.wholeSeconds)
        save(record, env)

        switch result {
        case .renewed:
            Self.logger.info("Claude sign-in renewal: Claude Code renewed its sign-in")
            let callback = lock.withLock { onRenewed }
            callback?()
        case .rewrittenNotReadableQuietly:
            Self.logger.notice("Claude sign-in renewal: Claude Code rewrote its sign-in; it cannot be read back without a dialog")
        case .notRenewed(let reason):
            let minutes = Int(ClaudeSignInRenewalPolicy.interval(afterFailures: record.consecutiveFailures) / 60)
            Self.logger.notice("Claude sign-in renewal: not renewed (\(String(describing: reason), privacy: .public)); next try in \(minutes, privacy: .public) min at the earliest")
        }
        return .ran(result)
    }

    /// The first reason not to start, cheapest questions first.
    private func gate(_ env: Environment, userAsked: Bool) -> ClaudeSignInRenewalSkip? {
        if env.isSandboxed() { return .sandboxed }
        if !env.allowedBySettings() { return .notAllowedBySettings }
        if env.isScreenLocked() ?? true { return .screenLocked }
        let itemDate = env.itemModified()
        guard let itemDate else { return .itemDateUnreadable }
        if !ClaudeSignInRenewalPolicy.allows(
            now: env.now(), record: load(env), userAsked: userAsked,
            itemDate: ClaudeSignInRenewalRun.wholeSeconds(itemDate)
        ) {
            return .backingOff
        }
        if env.findClaudeBinary() == nil { return .noClaudeBinary }
        return nil
    }

    func load(_ env: Environment) -> ClaudeSignInRenewalRecord {
        let epoch = env.defaults.double(forKey: Self.lastAttemptKey)
        return ClaudeSignInRenewalRecord(
            lastAttemptAt: epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil,
            consecutiveFailures: max(0, env.defaults.integer(forKey: Self.failuresKey)),
            itemDateAfterLastAttempt: env.defaults.object(forKey: Self.itemDateKey) as? Int
        )
    }

    private func save(_ record: ClaudeSignInRenewalRecord, _ env: Environment) {
        if let last = record.lastAttemptAt {
            env.defaults.set(last.timeIntervalSince1970, forKey: Self.lastAttemptKey)
        } else {
            env.defaults.removeObject(forKey: Self.lastAttemptKey)
        }
        env.defaults.set(record.consecutiveFailures, forKey: Self.failuresKey)
        if let date = record.itemDateAfterLastAttempt {
            env.defaults.set(date, forKey: Self.itemDateKey)
        } else {
            env.defaults.removeObject(forKey: Self.itemDateKey)
        }
    }

    // MARK: - Live probes

    /// Locked, or this user not at the console. nil when there is no session
    /// to ask.
    static func liveScreenLocked() -> Bool? {
        screenLocked(session: CGSessionCopyCurrentDictionary() as? [String: Any])
    }

    /// The session dictionary's console key. Spelled "kCGSSessionOnConsoleKey"
    /// (two S): the constant's name is not its value, which a literal of the
    /// name got wrong (found by the live trial, 2026-11-24).
    static let onConsoleKey: String = kCGSessionOnConsoleKey

    /// Unlocked only when the session says this user is at the console
    /// (`onConsoleKey` true) and does not say the screen is locked
    /// (`CGSSessionScreenIsLocked`, undocumented, present only while locked).
    static func screenLocked(session: [String: Any]?) -> Bool? {
        guard let session else { return nil }
        guard session[onConsoleKey] as? Bool == true else { return true }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// The item read back without a dialog, through Settings › Privacy's
    /// guard. It refreshes the app's copy as a collection's read would.
    static func liveVerify(excluding: String?, now: () -> Date = { Date() }) -> ClaudeSignInRenewalVerdict {
        let log = ClaudeKeychainReadLog()
        let creds = ClaudeKeychainReadLog.$current.withValue(log) {
            ClaudeCredentials.readKeychainCredentialsQuietlyIfAllowed()
        }
        return verdict(creds: creds, miss: log.miss, now: now(), excluding: excluding)
    }

    /// A login counts as renewed only as a token other than the expired one
    /// (`excluding`, its fingerprint), with an expiry at least five minutes
    /// away. Without an expiry nothing can be said: it may be the old token.
    static func verdict(
        creds: ClaudeCredentials.Creds?, miss: ClaudeKeychainMiss?, now: Date, excluding: String? = nil
    ) -> ClaudeSignInRenewalVerdict {
        if let creds {
            if let excluding, ClaudeOAuthBackoffState.fingerprint(forToken: creds.accessToken) == excluding {
                return .stillExpired
            }
            guard let expiresAt = creds.expiresAt else { return .notReadableQuietly }
            return expiresAt > now.addingTimeInterval(5 * 60) ? .current : .stillExpired
        }
        if miss == .expiredLogin { return .stillExpired }
        return .notReadableQuietly
    }

    /// Claude Code's refresh locks: `~/.claude/.oauth_refresh.lock` and the
    /// older `~/.claude.lock` (proper-lockfile directories, touched every
    /// 5 s while held, stale after 60 s).
    static func liveRefreshLockHeld(now: Date = Date()) -> Bool {
        refreshLockHeld(home: ClaudeCredentials.realHomeDir, now: now)
    }

    static func refreshLockHeld(home homePath: String, now: Date) -> Bool {
        let home = homePath as NSString
        let paths = [
            home.appendingPathComponent(".claude/.oauth_refresh.lock"),
            home.appendingPathComponent(".claude.lock"),
        ]
        return paths.contains { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date else { return false }
            return now.timeIntervalSince(modified) < 60
        }
    }

    /// `flock` on a file in the temporary folder, held for the attempt.
    static func liveInstanceLock() -> (() -> Void)? {
        let path = NSTemporaryDirectory() + "clipulse_claude_renewal.lock"
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return nil }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return {
            flock(fd, LOCK_UN)
            close(fd)
        }
    }
}

#if DEVID_BUILD
/// Claude Code started in a pseudo-terminal, in a process group of its own
/// from the moment it runs. Developer ID build only.
final class ClaudeSignInRenewalProcess: ClaudeSignInRenewalChild {
    /// The command line, minus the binary.
    ///
    /// - `--safe-mode` (Claude Code 2.1.330): none of the user's plugins,
    ///   hooks, MCP servers, skills or CLAUDE.md, while the stored login is
    ///   used as usual. Measured: no MCP server starts, the bootstrap request
    ///   still goes out. A Claude Code without it refuses the option and
    ///   exits, which reads as "not renewed".
    /// - No `--bare`, unlike the `/usage` probe: bare mode never reads the
    ///   claude.ai login, so it would renew nothing.
    /// - `--tools ""`: no built-in tools. Nothing is typed anyway.
    /// - `disableAllHooks`, `remoteControlAtStartup:false` (both also passed by
    ///   CodexBar): no hooks from managed settings, and no Remote Control
    ///   session for a start the user did not make.
    static let launchArguments: [String] = [
        "--safe-mode",
        "--tools", "",
        "--strict-mcp-config",
        "--settings", #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#,
    ]

    /// What the app's environment loses: every `ANTHROPIC_*` (an API key or
    /// base URL would sign Claude Code in with something other than the item
    /// CLI Pulse watches), and every name starting with `CLAUDE`. That covers
    /// `CLAUDE_CONFIG_DIR` and `CLAUDE_SECURESTORAGE_CONFIG_DIR`, which are part
    /// of the item's name; `CLAUDE_CODE_OAUTH_TOKEN`; bare mode; and the
    /// markers a Claude Code session gives the processes it starts
    /// (`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`, …), for an app opened from a
    /// terminal inside one. Measured 2026-11-24: with those inherited, Claude
    /// Code ignored SIGINT and saved no transcript. Also `CODEXBAR_*`, as the
    /// `/usage` probe drops.
    static let removedEnvironmentPrefixes = ["ANTHROPIC_", "CLAUDE", "CODEXBAR_"]
    /// Kept although `CLAUDE`-prefixed: the user's own choice to cut Claude
    /// Code's nonessential traffic holds here too, even if the renewal then
    /// cannot work. `DISABLE_TELEMETRY` and the like have no prefix and stay.
    static let keptEnvironmentNames: Set<String> = ["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"]

    /// The app's environment without those, and with Claude Code's updater
    /// off, so a start the user did not make downloads no new Claude Code.
    static func launchEnvironment(
        base: [String: String] = ProcessInfo.processInfo.environment, workingDirectory: String
    ) -> [String: String] {
        var env = base.filter { key, _ in
            keptEnvironmentNames.contains(key)
                || !removedEnvironmentPrefixes.contains(where: { key.hasPrefix($0) })
        }
        env["DISABLE_AUTOUPDATER"] = "1"
        env["PWD"] = workingDirectory
        if env["TERM"] == nil { env["TERM"] = "xterm-256color" }
        return env
    }

    /// An empty folder of the renewal's own. No `.claude/` in it, unlike the
    /// `/usage` probe's: with 2.1.330 an empty folder asked no trust question.
    static func workingDirectory() -> String {
        let dir = NSTemporaryDirectory() + "clipulse_claude_renewal"
        try? FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir
    }

    let pid: pid_t
    private let primaryFD: Int32
    private let lock = NSLock()
    private var exited = false
    private var finished = false

    private init(pid: pid_t, primaryFD: Int32) {
        self.pid = pid
        self.primaryFD = primaryFD
    }

    static func spawn(binary: String) -> ClaudeSignInRenewalProcess? {
        var primaryFD: Int32 = -1
        var secondaryFD: Int32 = -1
        var size = winsize(ws_row: 50, ws_col: 160, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primaryFD, &secondaryFD, nil, nil, &size) == 0 else { return nil }
        defer { close(secondaryFD) }
        _ = fcntl(primaryFD, F_SETFL, fcntl(primaryFD, F_GETFL) | O_NONBLOCK)
        _ = fcntl(primaryFD, F_SETFD, FD_CLOEXEC)

        let workDir = workingDirectory()
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, secondaryFD, STDERR_FILENO)
        posix_spawn_file_actions_addchdir_np(&fileActions, workDir)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Its own process group from exec on, so every process it starts can
        // be signalled together; only the three descriptors above inherited;
        // default signal handling and an empty mask, whatever the app's.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
            | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        // `sigset_t` is a 32-bit mask on Darwin; `sigfillset`/`sigemptyset`
        // are macros there.
        var allSignals: sigset_t = ~0
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        var noSignals: sigset_t = 0
        posix_spawnattr_setsigmask(&attributes, &noSignals)

        let argv = [binary] + launchArguments
        let envp = launchEnvironment(workingDirectory: workDir).map { "\($0.key)=\($0.value)" }
        var cArgv: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) } + [nil]
        var cEnvp: [UnsafeMutablePointer<CChar>?] = envp.map { strdup($0) } + [nil]
        defer {
            cArgv.forEach { free($0) }
            cEnvp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, binary, &fileActions, &attributes, &cArgv, &cEnvp)
        guard status == 0, pid > 0 else {
            close(primaryFD)
            return nil
        }
        return ClaudeSignInRenewalProcess(pid: pid, primaryFD: primaryFD)
    }

    func readAvailable(max: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: Swift.min(max, 64 * 1024))
        let n = read(primaryFD, &buffer, buffer.count)
        return n > 0 ? Data(buffer.prefix(n)) : Data()
    }

    var hasExited: Bool {
        lock.withLock {
            if exited || finished { return true }
            // WNOWAIT: seen, not reaped. The pid stays reserved until
            // `finish`, so signals to its group cannot reach a stranger.
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0, info.si_pid == pid {
                exited = true
            }
            return exited
        }
    }

    func interrupt() {
        lock.withLock { if !finished { _ = kill(pid, SIGINT) } }
    }

    func finish() {
        lock.withLock {
            guard !finished else { return }
            // It has exited (or this is the last word anyway): anything it
            // started and left behind goes too, while the unreaped process
            // still holds the group's number. It does its refreshing itself,
            // so nothing here can cut one short.
            _ = kill(-pid, SIGTERM)
            _ = kill(-pid, SIGKILL)
            var status: Int32 = 0
            // Retried on EINTR; ECHILD means it is reaped already.
            while waitpid(pid, &status, 0) == -1, errno == EINTR {}
            close(primaryFD)
            finished = true
        }
    }
}
#endif
#endif
