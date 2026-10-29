#if os(macOS)
import Darwin
import Foundation
import Sentry

// 1.60: a probe for a main thread that stops answering.
//
// Sentry's own app-hang tracker already files a report at three seconds, with
// stacks. What it cannot say is what the main thread was doing in the kernel:
// running, parked in a wait, or suspended; and which run-loop mode it was in.
// Those two facts separate "our code is busy" from "the thread is parked and
// nobody wakes it". This probe adds them, once, when the stall passes ten
// seconds. It reports no stack: the hang tracker's report has the stacks, and
// suspending the main thread to walk its stack would change the state we are
// measuring.
//
// Three parts:
//   * `StallDetector`    a pure value: thresholds, the per-episode latch and
//                        the per-launch cap. No threads, no clocks.
//   * `MainThreadSampler` `thread_info` on the main thread's port.
//   * `MainThreadStallProbe` the watchdog thread that ties them together.

// MARK: - Detector

/// Decides, from a stream of watchdog ticks, when a main-thread stall is worth
/// a report. A pure value type: the caller supplies the uptime clock.
struct StallDetector {
    struct Configuration: Equatable, Sendable {
        /// Seconds between watchdog ticks.
        var pingInterval: TimeInterval
        /// A stall this long (or longer) is reported.
        var threshold: TimeInterval
        /// A tick that arrives later than `pingInterval + oversleepSlack`
        /// after the previous one means the watchdog itself was not running
        /// (a stopped process, a debugger pause, a starved machine): what it
        /// measured then says nothing about the main thread.
        var oversleepSlack: TimeInterval

        static let production = Configuration(pingInterval: 2, threshold: 10, oversleepSlack: 3)
    }

    enum Verdict: Equatable {
        /// Nothing to do.
        case quiet
        /// The tick came too late to be trusted; the episode's clock restarts.
        case discarded
        /// The main thread has not answered for `seconds`, and this episode
        /// has not been reported. Returned once per episode.
        case stalled(seconds: TimeInterval)
    }

    let configuration: Configuration
    private var lastTick: TimeInterval?
    /// The stall is measured from here at the earliest: a discarded tick moves
    /// it up to that tick.
    private var floor: TimeInterval = 0
    private var episodeLatched = false
    private var unexplainedUsed = false
    private var explainedUsed = false

    init(configuration: Configuration = .production) {
        self.configuration = configuration
    }

    /// One watchdog tick.
    ///
    /// - Parameters:
    ///   - uptime: now, on a clock that does not advance while the Mac sleeps.
    ///   - unansweredSince: when the oldest ping the main thread has not
    ///     answered was posted; `nil` when it has answered everything.
    mutating func observe(uptime: TimeInterval, unansweredSince: TimeInterval?) -> Verdict {
        defer { lastTick = uptime }

        guard let since = unansweredSince else {
            // The main thread answered: the episode, if there was one, is over.
            episodeLatched = false
            floor = 0
            return .quiet
        }
        if let lastTick, uptime - lastTick > configuration.pingInterval + configuration.oversleepSlack {
            floor = uptime
            return .discarded
        }
        let stall = uptime - max(since, floor)
        guard stall >= configuration.threshold else { return .quiet }
        guard !episodeLatched else { return .quiet }
        episodeLatched = true
        return .stalled(seconds: stall)
    }

    /// Time spent on something other than ticking (taking a sample) is not an
    /// oversleep. Call it when that work is done.
    mutating func resume(at uptime: TimeInterval) {
        lastTick = uptime
    }

    /// Whether either per-launch report slot is still free.
    var hasFreeSlot: Bool { !unexplainedUsed || !explainedUsed }

    /// Takes one of the two per-launch report slots, if it is free. An
    /// `explained` stall (the run loop was in menu tracking or a modal panel)
    /// has a slot of its own, so a benign one cannot use up the budget for an
    /// unexplained one.
    mutating func claimSlot(explained: Bool) -> Bool {
        if explained {
            guard !explainedUsed else { return false }
            explainedUsed = true
        } else {
            guard !unexplainedUsed else { return false }
            unexplainedUsed = true
        }
        return true
    }
}

// MARK: - What the main thread was doing

/// The kernel's run state of a thread, as a closed set of words.
enum MainThreadRunState: String, CaseIterable, Sendable {
    case running
    case waiting
    case stopped
    case uninterruptible
    case halted
    /// `thread_info` failed.
    case unknown

    init(machRunState: Int32) {
        switch machRunState {
        case TH_STATE_RUNNING: self = .running
        case TH_STATE_STOPPED: self = .stopped
        case TH_STATE_WAITING: self = .waiting
        case TH_STATE_UNINTERRUPTIBLE: self = .uninterruptible
        case TH_STATE_HALTED: self = .halted
        default: self = .unknown
        }
    }
}

/// Which run-loop mode the main run loop was in, as a closed set of words.
/// The mode's own name never leaves the device: a modal panel's mode carries a
/// unique suffix, and only the words below are sent.
enum RunLoopModeWord: String, CaseIterable, Sendable {
    case `default`
    case eventTracking = "event_tracking"
    case modalPanel = "modal_panel"
    /// The run loop was not running a mode.
    case none
    /// The read did not come back in time (the run loop's lock was held by a
    /// thread that is not running).
    case unreadable
    case other

    init(mode: String?) {
        switch mode {
        case nil: self = .none
        case "kCFRunLoopDefaultMode": self = .default
        case "NSEventTrackingRunLoopMode": self = .eventTracking
        case "NSModalPanelRunLoopMode": self = .modalPanel
        default: self = .other
        }
    }

    /// Menu tracking and modal panels block the main thread for as long as the
    /// user takes, by design.
    var isExplained: Bool { self == .eventTracking || self == .modalPanel }
}

/// What three looks at the main thread, 100 ms apart, found.
struct MainThreadSample: Equatable, Sendable {
    var runState: MainThreadRunState
    var suspendCount: Int
    /// Processor time (user + system) the thread used between the first look
    /// and the last, in milliseconds.
    var cpuMilliseconds: Int
    /// The kernel's id of the thread that was looked at. Not sent anywhere:
    /// the tests compare it with the main thread's own.
    var threadID: UInt64
}

/// Reads `thread_info` for one thread port.
struct MainThreadSampler: Sendable {
    let port: mach_port_t
    /// Looks at the thread `looks` times, `gap` seconds apart.
    var looks = 3
    var gap: TimeInterval = 0.1

    /// The port of the calling thread. Only the main thread's answer means
    /// anything, so this returns `nil` anywhere else.
    static func forCurrentThreadIfMain() -> MainThreadSampler? {
        guard pthread_main_np() != 0 else { return nil }
        return MainThreadSampler(port: pthread_mach_thread_np(pthread_self()))
    }

    func sample() -> MainThreadSample {
        var states: [MainThreadRunState] = []
        var suspend = 0
        var firstCPU: Int?
        var lastCPU = 0
        for index in 0..<max(looks, 1) {
            if index > 0 { Foundation.Thread.sleep(forTimeInterval: gap) }
            guard let info = Self.basicInfo(of: port) else {
                states.append(.unknown)
                continue
            }
            states.append(MainThreadRunState(machRunState: info.run_state))
            suspend = max(suspend, Int(info.suspend_count))
            let cpu = Self.microseconds(info.user_time) + Self.microseconds(info.system_time)
            if firstCPU == nil { firstCPU = cpu }
            lastCPU = cpu
        }
        // A thread seen running once was busy; otherwise the last look stands.
        let state: MainThreadRunState = states.contains(.running) ? .running : (states.last ?? .unknown)
        return MainThreadSample(
            runState: state,
            suspendCount: suspend,
            cpuMilliseconds: max(0, lastCPU - (firstCPU ?? lastCPU)) / 1000,
            threadID: Self.threadID(of: port) ?? 0
        )
    }

    private static func microseconds(_ value: time_value_t) -> Int {
        Int(value.seconds) * 1_000_000 + Int(value.microseconds)
    }

    private static func basicInfo(of port: mach_port_t) -> thread_basic_info? {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info : nil
    }

    private static func threadID(of port: mach_port_t) -> UInt64? {
        var info = thread_identifier_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_identifier_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_IDENTIFIER_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.thread_id : nil
    }
}

/// Reads the main run loop's current mode without being able to hang the
/// caller. `CFRunLoopCopyCurrentMode` takes the run loop's lock, and a main
/// thread that is suspended while holding it would never give it back; so the
/// read runs on a throwaway thread and is abandoned after `timeout`. One is
/// started per sampled stall, and none once both report slots are spent.
struct RunLoopModeReader: Sendable {
    var timeout: TimeInterval = 1
    /// The read itself. Replaced in tests by one that never returns.
    var copyCurrentMode: @Sendable () -> String? = {
        guard let mode = CFRunLoopCopyCurrentMode(CFRunLoopGetMain()) else { return nil }
        return mode.rawValue as String
    }

    func read() -> RunLoopModeWord {
        let box = ModeBox()
        let done = DispatchSemaphore(value: 0)
        let copy = copyCurrentMode
        let thread = Foundation.Thread {
            box.set(copy())
            done.signal()
        }
        thread.name = Self.threadName
        thread.qualityOfService = .utility
        thread.start()
        guard done.wait(timeout: .now() + timeout) == .success else { return .unreadable }
        return RunLoopModeWord(mode: box.value)
    }

    /// A constant, not an inline literal: scripts/check_quota_tier_names.py
    /// reads every `name = "…"` as a quota tier name.
    private static let threadName = "com.clipulse.stall-probe.mode"

    private final class ModeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: String?
        var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ mode: String?) { lock.lock(); stored = mode; lock.unlock() }
    }
}

// MARK: - Report

/// The whole of what a stall report says. Every field is an integer or a word
/// from a closed set; nothing comes from the user's data.
struct StallReport: Equatable, Sendable {
    /// How long the main thread had not answered, in seconds. Sent as whole seconds.
    var stall: TimeInterval
    var runState: MainThreadRunState
    var suspendCount: Int
    var cpuMilliseconds: Int
    var runLoopMode: RunLoopModeWord
    var channel: DistributionChannel

    /// The main thread was waiting in a run-loop mode that waits for the user
    /// on purpose. A thread that is *running* inside such a loop is busy with
    /// something (a handler called from the tracking loop), which is not
    /// benign, so it keeps the other slot.
    var explained: Bool { runLoopMode.isExplained && runState != .running }
}

/// Where stall reports go. A protocol so the tests can see every report
/// without starting Sentry (DEBUG builds never start it).
protocol StallReporter: Sendable {
    func report(_ report: StallReport)
}

struct SentryStallReporter: StallReporter {
    /// The event's fixed name; it is also its message, so the event carries no
    /// prose at all.
    static let eventName = "main-thread-stall"

    func report(_ report: StallReport) {
        SentrySDK.capture(event: Self.event(for: report)) { scope in
            Self.configure(scope)
        }
    }

    /// The event, before the SDK adds its standard envelope. `capture(event:)`
    /// is used rather than `capture(message:)`, and the event arrives with a
    /// thread list of its own: the SDK, with `attachStacktrace` on, would
    /// otherwise attach the stack of the calling thread, which is the
    /// watchdog's and says nothing about the stall.
    static func event(for report: StallReport) -> Event {
        let event = Event(level: .warning)
        event.message = SentryMessage(formatted: eventName)
        // Grouped by what the main thread was doing, a closed set, never by
        // stack or text.
        event.fingerprint = [eventName, report.runState.rawValue, report.runLoopMode.rawValue]
        event.tags = [
            "stall_s": String(Int(report.stall)),
            "main_run_state": report.runState.rawValue,
            "main_suspend_count": String(report.suspendCount),
            "main_cpu_ms": String(report.cpuMilliseconds),
            "runloop_mode": report.runLoopMode.rawValue,
            "channel": report.channel.rawValue,
            "explained": report.explained ? "true" : "false",
        ]
        let thread = SentryThread(threadId: 0)
        thread.name = MainThreadStallProbe.threadName
        thread.current = NSNumber(value: false)
        thread.crashed = NSNumber(value: false)
        event.threads = [thread]
        return event
    }

    /// What this report adds on the scope the SDK hands over (a copy of the
    /// current one, so a crash report keeps its own breadcrumbs).
    static func configure(_ scope: Scope) {
        // The report is the main thread's state; the last requests the app
        // made add nothing to it.
        scope.clearBreadcrumbs()
    }
}

// MARK: - Watchdog

/// Watches the main thread from a thread of its own, and files one report when
/// the main thread has not answered for ten seconds.
///
/// Policy:
///   * one report per stall episode (it ends when a ping is answered);
///   * at most two per launch: one where the run loop was in menu tracking or
///     a modal panel (`explained`), one for anything else;
///   * a tick that came late (the watchdog itself was not running), or a
///     process being debugged, reports nothing;
///   * nothing is written to disk.
public final class MainThreadStallProbe: @unchecked Sendable {
    public static let shared = MainThreadStallProbe()

    /// See `RunLoopModeReader.threadName` for why this is a constant.
    static let threadName = "com.clipulse.stall-probe"

    struct Dependencies: Sendable {
        var reporter: any StallReporter = SentryStallReporter()
        var channel: @Sendable () -> DistributionChannel = { DistributionChannel.detectCurrent() }
        var isBeingTraced: @Sendable () -> Bool = { MainThreadStallProbe.processIsBeingTraced() }
        var modeReader = RunLoopModeReader()
        var uptime: @Sendable () -> TimeInterval = { MainThreadStallProbe.systemUptime() }
    }

    private let configuration: StallDetector.Configuration
    private let dependencies: Dependencies
    private let sampleLooks: Int
    private let sampleGap: TimeInterval
    private let lock = NSLock()
    private var thread: Foundation.Thread?
    private let stopSignal = DispatchSemaphore(value: 0)
    private var stopped = false
    private var ticks = 0

    private convenience init() {
        self.init(configuration: .production, dependencies: Dependencies())
    }

    init(
        configuration: StallDetector.Configuration,
        dependencies: Dependencies,
        sampleLooks: Int = 3,
        sampleGap: TimeInterval = 0.1
    ) {
        self.configuration = configuration
        self.dependencies = dependencies
        self.sampleLooks = sampleLooks
        self.sampleGap = sampleGap
    }

    /// Starts the watchdog. Call it once, on the main thread, as early as
    /// possible: most stalls in the field come within seconds of launch. A
    /// second call, or a call from another thread, does nothing.
    public func start() {
        guard var sampler = MainThreadSampler.forCurrentThreadIfMain() else { return }
        sampler.looks = sampleLooks
        sampler.gap = sampleGap
        lock.lock()
        defer { lock.unlock() }
        guard thread == nil else { return }
        stopped = false
        while stopSignal.wait(timeout: .now()) == .success {}
        let watchdog = Foundation.Thread { [self] in run(sampler: sampler) }
        watchdog.name = Self.threadName
        watchdog.qualityOfService = .userInitiated
        thread = watchdog
        watchdog.start()
    }

    /// Ends the watchdog. Only the tests need it: nothing in the app stops the
    /// probe, so a stopped-and-restarted one (fresh report budgets) never
    /// happens outside them.
    func stop() {
        lock.lock()
        guard thread != nil else { lock.unlock(); return }
        stopped = true
        lock.unlock()
        stopSignal.signal()
    }

    /// Whether the watchdog thread is still in its loop (it leaves it only
    /// after `stop()`).
    var isAlive: Bool {
        lock.lock(); defer { lock.unlock() }
        return thread != nil
    }

    /// How many times the watchdog has gone round its loop.
    var tickCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ticks
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return thread != nil && !stopped
    }

    // MARK: Loop

    private func run(sampler: MainThreadSampler) {
        var detector = StallDetector(configuration: configuration)
        let answered = DispatchSemaphore(value: 0)
        var unansweredSince: TimeInterval?

        while true {
            let tickStart = dependencies.uptime()
            if unansweredSince == nil {
                unansweredSince = tickStart
                DispatchQueue.main.async { answered.signal() }
            }
            if answered.wait(timeout: .now() + configuration.pingInterval) == .success {
                unansweredSince = nil
            }
            let now = dependencies.uptime()
            lock.lock(); ticks += 1; lock.unlock()

            switch detector.observe(uptime: now, unansweredSince: unansweredSince) {
            case .quiet, .discarded:
                break
            case .stalled(let seconds):
                handleStall(seconds, observedAt: now, sampler: sampler, detector: &detector)
                detector.resume(at: dependencies.uptime())
            }

            // An answered ping came back at once: wait out the rest of the
            // interval. `stop()` ends the wait.
            let rest = configuration.pingInterval - (dependencies.uptime() - tickStart)
            if rest > 0, stopSignal.wait(timeout: .now() + rest) == .success { break }
            if isStopped { break }
        }
        lock.lock(); thread = nil; lock.unlock()
    }

    private var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    private func handleStall(
        _ crossed: TimeInterval,
        observedAt: TimeInterval,
        sampler: MainThreadSampler,
        detector: inout StallDetector
    ) {
        // Both reports of this launch are spent: skip the looks and the
        // throwaway thread.
        guard detector.hasFreeSlot else { return }
        // A debugger stops the main thread on purpose.
        guard !dependencies.isBeingTraced() else { return }
        let sample = sampler.sample()
        let mode = dependencies.modeReader.read()
        let candidate = StallReport(
            // Counted from the moment the detector crossed the threshold, which
            // already leaves out any stretch it discarded, plus the looks.
            stall: crossed + (dependencies.uptime() - observedAt),
            runState: sample.runState,
            suspendCount: sample.suspendCount,
            cpuMilliseconds: sample.cpuMilliseconds,
            runLoopMode: mode,
            channel: dependencies.channel())
        guard detector.claimSlot(explained: candidate.explained) else { return }
        dependencies.reporter.report(candidate)
    }

    // MARK: System

    /// Seconds since boot, not counting time the Mac slept.
    static func systemUptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    /// Whether a debugger is attached to this process (`P_TRACED`).
    static func processIsBeingTraced() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
}
#endif
