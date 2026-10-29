// 1.60: the main-thread stall probe.
//
// Four groups:
//   1. `StallDetector`, the pure rules: threshold, one report per episode, a
//      late watchdog tick discarded, two slots per launch.
//   2. The words: run states and run-loop modes map to closed sets and a
//      mode's own name never leaves.
//   3. What the Sentry event carries, checked on the event, on the scope, and
//      through a started SDK (which attaches a stack the event must not have).
//   4. The watchdog on real threads against the real main thread: a sleeping
//      one, a busy one, a suspended one, one that stays responsive, one that a
//      debugger holds, and a run-loop read that never returns. Each stall
//      lasts until the watchdog has done what the test waits for; nothing
//      asserts an upper bound on a time.
//
// macOS-gated: the probe is.

#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import CLIPulseCore

// MARK: - 1. Detector

final class StallDetectorTests: XCTestCase {

    private func detector() -> StallDetector {
        StallDetector(configuration: .init(pingInterval: 2, threshold: 10, oversleepSlack: 3))
    }

    func testNothingBelowTheThresholdOneReportAtItAndNoneWhileTheEpisodeContinues() {
        var detector = detector()
        // Ping posted at 0, never answered. Ticks every 2 s.
        for tick in [2.0, 4, 6, 8] {
            XCTAssertEqual(detector.observe(uptime: tick, unansweredSince: 0), .quiet, "tick \(tick)")
        }
        // Exactly the threshold counts.
        XCTAssertEqual(detector.observe(uptime: 10, unansweredSince: 0), .stalled(seconds: 10))
        for tick in [12.0, 14, 16, 18, 20, 22] {
            XCTAssertEqual(detector.observe(uptime: tick, unansweredSince: 0), .quiet,
                           "the same episode must not report again at \(tick)")
        }
    }

    func testAnAnswerEndsTheEpisodeAndTheNextOneIsReported() {
        var detector = detector()
        _ = detector.observe(uptime: 10, unansweredSince: 0)
        XCTAssertEqual(detector.observe(uptime: 12, unansweredSince: nil), .quiet)
        // A new ping at 14, unanswered.
        for tick in [16.0, 18, 20, 22] {
            XCTAssertEqual(detector.observe(uptime: tick, unansweredSince: 14), .quiet, "tick \(tick)")
        }
        XCTAssertEqual(detector.observe(uptime: 24, unansweredSince: 14), .stalled(seconds: 10))
    }

    func testATickThatCameThirtySecondsLateReportsNothingAndRestartsTheClock() {
        var detector = detector()
        XCTAssertEqual(detector.observe(uptime: 2, unansweredSince: 0), .quiet)
        XCTAssertEqual(detector.observe(uptime: 4, unansweredSince: 0), .quiet)
        // The watchdog itself was stopped for 30 s (a SIGSTOP, a debugger).
        XCTAssertEqual(detector.observe(uptime: 34, unansweredSince: 0), .discarded)
        // From then on the stall is counted from the tick that came back.
        for tick in [36.0, 38, 40, 42] {
            XCTAssertEqual(detector.observe(uptime: tick, unansweredSince: 0), .quiet, "tick \(tick)")
        }
        XCTAssertEqual(detector.observe(uptime: 44, unansweredSince: 0), .stalled(seconds: 10),
                       "a stall that really continues is still reported, after its own ten seconds")
    }

    func testTimeSpentSamplingIsNotAnOversleep() {
        var detector = detector()
        _ = detector.observe(uptime: 10, unansweredSince: 0)
        detector.resume(at: 15)   // the looks took 5 s
        // 17 is only 2 s after the resumption; without it the gap is 7 s, more
        // than an interval and its slack, and the tick would be discarded.
        XCTAssertEqual(detector.observe(uptime: 17, unansweredSince: 0), .quiet)
    }

    func testTwoReportsPerLaunchAndTheExplainedSlotIsSeparate() {
        var detector = detector()
        XCTAssertTrue(detector.claimSlot(explained: false))
        XCTAssertFalse(detector.claimSlot(explained: false), "a second unexplained stall is not reported")
        XCTAssertTrue(detector.claimSlot(explained: true),
                      "a menu-tracking stall must not have used up the slot of an unexplained one, or the reverse")
        XCTAssertFalse(detector.claimSlot(explained: true))
    }

    func testAnExplainedStallFirstLeavesTheUnexplainedSlotFree() {
        var detector = detector()
        XCTAssertTrue(detector.claimSlot(explained: true))
        XCTAssertFalse(detector.claimSlot(explained: true))
        XCTAssertTrue(detector.claimSlot(explained: false))
    }
}

// MARK: - 2. Words

final class MainThreadStallWordsTests: XCTestCase {

    func testRunLoopModesMapToTheClosedSetAndNeverPassThroughAName() {
        XCTAssertEqual(RunLoopModeWord(mode: "kCFRunLoopDefaultMode"), .default)
        XCTAssertEqual(RunLoopModeWord(mode: "NSEventTrackingRunLoopMode"), .eventTracking)
        XCTAssertEqual(RunLoopModeWord(mode: "NSModalPanelRunLoopMode"), .modalPanel)
        XCTAssertEqual(RunLoopModeWord(mode: nil), .none)

        // A mode with a unique suffix, or one the app made up, is `other`.
        let suffixed = "NSModalPanelRunLoopMode-\(UUID().uuidString)"
        XCTAssertEqual(RunLoopModeWord(mode: suffixed), .other)
        XCTAssertEqual(RunLoopModeWord(mode: "com.example.private-mode-name"), .other)
        XCTAssertFalse(RunLoopModeWord(mode: suffixed).rawValue.contains("-"))

        XCTAssertEqual(Set(RunLoopModeWord.allCases.map(\.rawValue)),
                       ["default", "event_tracking", "modal_panel", "none", "unreadable", "other"])
    }

    func testOnlyMenuTrackingAndModalPanelsAreExplained() {
        let explained = RunLoopModeWord.allCases.filter(\.isExplained)
        XCTAssertEqual(Set(explained), [.eventTracking, .modalPanel])
    }

    func testOnlyAWaitingThreadInATrackingLoopIsExplained() {
        func report(_ state: MainThreadRunState, _ mode: RunLoopModeWord) -> StallReport {
            StallReport(stall: 10, runState: state, suspendCount: 0, cpuMilliseconds: 0,
                        runLoopMode: mode, channel: .devid)
        }
        XCTAssertTrue(report(.waiting, .eventTracking).explained)
        XCTAssertTrue(report(.waiting, .modalPanel).explained)
        XCTAssertFalse(report(.running, .eventTracking).explained,
                       "a thread busy inside the tracking loop is not waiting for the user")
        XCTAssertFalse(report(.waiting, .default).explained)
        XCTAssertFalse(report(.waiting, .unreadable).explained)
    }

    func testRunStatesMapToWords() {
        XCTAssertEqual(MainThreadRunState(machRunState: TH_STATE_RUNNING), .running)
        XCTAssertEqual(MainThreadRunState(machRunState: TH_STATE_WAITING), .waiting)
        XCTAssertEqual(MainThreadRunState(machRunState: TH_STATE_STOPPED), .stopped)
        XCTAssertEqual(MainThreadRunState(machRunState: TH_STATE_UNINTERRUPTIBLE), .uninterruptible)
        XCTAssertEqual(MainThreadRunState(machRunState: TH_STATE_HALTED), .halted)
        XCTAssertEqual(MainThreadRunState(machRunState: 99), .unknown)
    }

    func testAModeReadThatNeverReturnsIsUnreadableAndDoesNotHoldTheCaller() {
        // The run loop's lock can be held by a thread that is not running;
        // the real read would then never come back. Stand in for it.
        let forever = DispatchSemaphore(value: 0)
        var reader = RunLoopModeReader(timeout: 0.2)
        reader.copyCurrentMode = { forever.wait(); return "kCFRunLoopDefaultMode" }
        XCTAssertEqual(reader.read(), .unreadable)
        forever.signal()   // let the abandoned thread end

        var quick = RunLoopModeReader(timeout: 2)
        quick.copyCurrentMode = { "NSEventTrackingRunLoopMode" }
        XCTAssertEqual(quick.read(), .eventTracking)
    }
}

// MARK: - 3. The event

final class SentryStallReporterTests: XCTestCase {

    static let report = StallReport(
        stall: 12.7, runState: .waiting, suspendCount: 0, cpuMilliseconds: 3,
        runLoopMode: .eventTracking, channel: .devid)

    func testTheEventCarriesOnlyTheClosedTagsAndNoStack() {
        let event = SentryStallReporter.event(for: Self.report)

        XCTAssertEqual(event.tags, [
            "stall_s": "12",
            "main_run_state": "waiting",
            "main_suspend_count": "0",
            "main_cpu_ms": "3",
            "runloop_mode": "event_tracking",
            "channel": "devid",
            "explained": "true",
        ])
        XCTAssertEqual(event.fingerprint, ["main-thread-stall", "waiting", "event_tracking"])
        XCTAssertEqual(event.level, .warning)
        XCTAssertEqual(event.message?.formatted, "main-thread-stall")
        XCTAssertNil(event.exceptions)
        XCTAssertNil(event.user)
        XCTAssertNil(event.extra)
        XCTAssertNil(event.context)
        XCTAssertNil(event.breadcrumbs)
        for thread in event.threads ?? [] {
            XCTAssertNil(thread.stacktrace, "the event must not carry a stack")
        }
    }

    func testTheEventAddsNoBreadcrumbsToTheScopeCopy() throws {
        let current = Scope()
        current.addBreadcrumb(Breadcrumb(level: .info, category: "http"))
        current.addBreadcrumb(Breadcrumb(level: .info, category: "app.lifecycle"))
        let copy = Scope(scope: current)
        XCTAssertEqual((copy.serialize()["breadcrumbs"] as? [Any])?.count, 2,
                       "control: the copy did not carry the breadcrumbs, so their removal proves nothing")

        SentryStallReporter.configure(copy)

        XCTAssertNil(copy.serialize()["breadcrumbs"], "the stall event must carry no breadcrumbs (PRIVACY.md)")
        XCTAssertEqual((current.serialize()["breadcrumbs"] as? [Any])?.count, 2,
                       "a crash report keeps its own")
    }

    func testTheScrubberKeepsEveryTag() throws {
        let event = SentryStallReporter.event(for: Self.report)
        let scrubbed = try XCTUnwrap(SentryLogger.scrub(event: event))
        XCTAssertEqual(scrubbed.tags, SentryStallReporter.event(for: Self.report).tags,
                       "a tag name that looks sensitive would be replaced with [scrubbed]")
        XCTAssertEqual(scrubbed.message?.formatted, "main-thread-stall")
    }

    /// With `attachStacktrace` on (as `SentryLogger` has it) the SDK adds the
    /// calling thread's stack to any event without threads. That would be the
    /// watchdog's, and would read as the stall's. Run the real SDK, drop the
    /// event in `beforeSend`, and look at what it was about to send.
    func testTheStartedSDKAttachesNoStackToTheEvent() throws {
        let seen = try Self.captureThroughSDK(attachStacktrace: true) {
            SentryStallReporter().report(Self.report)
        }
        XCTAssertEqual(seen.message?.formatted, "main-thread-stall")
        XCTAssertFalse((seen.threads ?? []).contains { $0.stacktrace != nil },
                       "the SDK attached the watchdog thread's stack")

        // Control: an event without a threads list of its own does get one.
        let plain = try Self.captureThroughSDK(attachStacktrace: true) {
            let event = SentryStallReporter.event(for: Self.report)
            event.threads = nil
            SentrySDK.capture(event: event)
        }
        XCTAssertTrue((plain.threads ?? []).contains { $0.stacktrace != nil },
                      "control: the SDK did not attach a stack to a bare event, so the check above proves nothing")
    }

    private static func captureThroughSDK(attachStacktrace: Bool, _ body: () -> Void) throws -> Event {
        let lock = NSLock()
        var captured: Event?
        let arrived = DispatchSemaphore(value: 0)
        SentrySDK.start { options in
            options.dsn = "https://public@127.0.0.1.invalid/1"
            options.attachStacktrace = attachStacktrace
            options.enableCrashHandler = false
            options.enableAutoSessionTracking = false
            options.enableAppHangTracking = false
            options.enableWatchdogTerminationTracking = false
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableAutoPerformanceTracing = false
            options.enableCaptureFailedRequests = false
            options.beforeSend = { event in
                lock.lock(); captured = event; lock.unlock()
                arrived.signal()
                return nil   // nothing leaves the test
            }
        }
        defer { SentrySDK.close() }
        body()
        XCTAssertEqual(arrived.wait(timeout: .now() + 5), .success, "beforeSend never ran")
        lock.lock(); defer { lock.unlock() }
        return try XCTUnwrap(captured)
    }
}

// MARK: - 4. The watchdog on real threads
//
// No test here holds the main thread for a fixed time and hopes the watchdog
// looked at it meanwhile: on a loaded CI runner the watchdog can run late, and
// a stall that ended before the looks were taken gave a thread that was
// running again (#715's failure: a menu-tracking stall seen as `running`, so
// unexplained, so both slots' outcomes shifted). Instead a stall lasts until
// the watchdog has done what the test waits for: filed its report, asked the
// debugger check, or gone round its loop enough times that the stall must
// have crossed the threshold and been handled. The only clocks left are
// deadlines that end a test that would otherwise hang.

private final class RecordingStallReporter: StallReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StallReport] = []
    private let arrived = DispatchSemaphore(value: 0)
    var reports: [StallReport] { lock.lock(); defer { lock.unlock() }; return stored }
    var count: Int { lock.lock(); defer { lock.unlock() }; return stored.count }

    func report(_ report: StallReport) {
        lock.lock(); stored.append(report); lock.unlock()
        arrived.signal()
    }

    /// Parks the calling thread in a semaphore wait (to the kernel: waiting,
    /// not running) until a report not yet waited for has been filed. False
    /// after `timeout`.
    func waitForNextReport(timeout: TimeInterval = 15) -> Bool {
        arrived.wait(timeout: .now() + timeout) == .success
    }
}

/// A counter a `@Sendable` closure can bump.
private final class StallTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
    func increment() { lock.lock(); stored += 1; lock.unlock() }
}

/// Run-loop mode reads, counted by the phase of the test they happened in.
private final class PhasedModeReads: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var counts: [Int: Int] = [:]
    var phase: Int {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
    var readsByPhase: [Int: Int] { lock.lock(); defer { lock.unlock() }; return counts }

    /// Phase 1 is menu tracking; any other phase is no mode at all.
    func read() -> String? {
        lock.lock(); defer { lock.unlock() }
        counts[current, default: 0] += 1
        return current == 1 ? "NSEventTrackingRunLoopMode" : nil
    }
}

final class MainThreadStallProbeTests: XCTestCase {

    private static let pingInterval: TimeInterval = 0.1
    private static let threshold: TimeInterval = 0.5

    private var probes: [MainThreadStallProbe] = []

    override func tearDown() {
        probes.forEach { $0.stop() }
        probes = []
        super.tearDown()
    }

    /// A short threshold, so a stall is seen within about a second on a quiet
    /// machine (each test holds main until the watchdog is done, however long
    /// that takes), and a slack so wide that a slow runner does not make the
    /// watchdog look asleep.
    private func makeProbe(
        reporter: RecordingStallReporter,
        threshold: TimeInterval = MainThreadStallProbeTests.threshold,
        traced: (@Sendable () -> Bool)? = nil,
        modeReader: RunLoopModeReader = RunLoopModeReader(timeout: 1)
    ) -> MainThreadStallProbe {
        var dependencies = MainThreadStallProbe.Dependencies()
        dependencies.reporter = reporter
        dependencies.channel = { .devid }
        dependencies.isBeingTraced = traced ?? { false }
        dependencies.modeReader = modeReader
        let probe = MainThreadStallProbe(
            configuration: .init(pingInterval: Self.pingInterval, threshold: threshold, oversleepSlack: 30),
            dependencies: dependencies,
            sampleLooks: 3,
            sampleGap: 0.1)
        probes.append(probe)
        return probe
    }

    /// Lets the main queue run, so pings are answered, for `seconds`.
    private func spinMainRunLoop(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    /// Spins the main run loop until `condition` holds or `limit` passes.
    private func waitSpinning(limit: TimeInterval = 4, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(limit)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }

    /// Lets main answer until the watchdog has seen the answer, so a stall
    /// episode is over and the next stall is a new one. Main runs its queue
    /// (the outstanding ping) first; the watchdog takes the answer on its next
    /// wait, at the latest one loop later, so three loops are plenty.
    private func answerUntilTheEpisodeEnds(_ probe: MainThreadStallProbe) {
        spinMainRunLoop(0.05)
        let target = probe.tickCount + 3
        waitSpinning(limit: 15) { probe.tickCount >= target }
        XCTAssertGreaterThanOrEqual(probe.tickCount, target, "the watchdog stopped going round its loop")
    }

    /// How many watchdog loops, counted from the moment main stops answering,
    /// guarantee that the stall has crossed `threshold` and been handled.
    ///   * The ping the stall is measured from is posted at the start of the
    ///     third loop at the latest. The loop under way may have timed out on
    ///     a ping that main then answered; the next loop takes that late answer
    ///     at once and posts nothing; the one after it posts a fresh ping.
    ///   * From that ping on, every loop waits out a whole ping interval on a
    ///     ping that is never answered, so `threshold / pingInterval` loops
    ///     cross the threshold.
    ///   * The loop that crosses it handles the stall before the next one
    ///     counts, so one more loop means the handling is over.
    /// Two more on top, for rounding.
    private func loopsToCrossAndHandle(_ threshold: TimeInterval) -> Int {
        3 + Int((threshold / Self.pingInterval).rounded(.up)) + 1 + 2
    }

    /// Holds the main thread (it answers nothing) until the watchdog has gone
    /// round its loop `loops` more times. False if that took longer than
    /// `limit`.
    private func holdMain(until probe: MainThreadStallProbe, hasLooped loops: Int, limit: TimeInterval = 15) -> Bool {
        let target = probe.tickCount + loops
        let deadline = MainThreadStallProbe.systemUptime() + limit
        while probe.tickCount < target {
            if MainThreadStallProbe.systemUptime() > deadline { return false }
            usleep(2_000)
        }
        return true
    }

    private func mainThreadID() -> UInt64 {
        var id: UInt64 = 0
        pthread_threadid_np(pthread_self(), &id)
        return id
    }

    // The tests below run on the process's main thread.

    func testASleepingMainThreadIsReportedOnceAsWaitingWithNoSuspension() {
        XCTAssertTrue(Thread.isMainThread, "the test must run on the main thread")
        let reporter = RecordingStallReporter()
        let probe = makeProbe(reporter: reporter, modeReader: RunLoopModeReader(timeout: 5))
        probe.start()
        XCTAssertTrue(probe.isRunning)
        spinMainRunLoop(0.4)   // answered pings, so the stall starts later
        XCTAssertEqual(reporter.count, 0, "nothing is reported while main answers")

        // Main parks in a semaphore wait until the report is filed, so every
        // look the watchdog takes, however late, finds it waiting.
        XCTAssertTrue(reporter.waitForNextReport(), "the stall was never reported")

        answerUntilTheEpisodeEnds(probe)   // an episode ends with an answer; nothing more may come
        XCTAssertEqual(reporter.count, 1)
        let report = reporter.reports.first
        XCTAssertEqual(report?.runState, .waiting)
        XCTAssertEqual(report?.suspendCount, 0)
        XCTAssertGreaterThanOrEqual(report?.stall ?? 0, Self.threshold)
        XCTAssertEqual(report?.channel, .devid)
        XCTAssertNotEqual(report?.runLoopMode, .unreadable, "nothing held the run loop's lock")
    }

    func testAMainThreadThatStaysResponsiveIsNeverReported() {
        let reporter = RecordingStallReporter()
        let probe = makeProbe(reporter: reporter, threshold: 1.5)
        probe.start()
        // Answering all the way, for longer than the threshold.
        spinMainRunLoop(2.5)
        XCTAssertGreaterThan(probe.tickCount, 5, "control: the watchdog did run")
        XCTAssertEqual(reporter.count, 0)
    }

    func testABusyMainThreadIsRunningAndTheThreadSampledIsTheMainThread() {
        let reporter = RecordingStallReporter()
        let sampler = MainThreadSampler.forCurrentThreadIfMain()
        XCTAssertNotNil(sampler)
        makeProbe(reporter: reporter).start()
        spinMainRunLoop(0.3)

        // Busy until the report is filed, so the looks all fall inside the spin.
        let deadline = MainThreadStallProbe.systemUptime() + 15
        var x = 0.0
        while reporter.count == 0 && MainThreadStallProbe.systemUptime() < deadline { x += sin(x) + 1 }
        XCTAssertFalse(x.isNaN)

        let report = reporter.reports.first
        XCTAssertNotNil(report, "the busy stall was never reported")
        XCTAssertEqual(report?.runState, .running)
        // A sleeping thread uses none; a spinning one uses most of the 200 ms
        // the looks span, unless the runner starves it, so the bar is low.
        XCTAssertGreaterThanOrEqual(report?.cpuMilliseconds ?? 0, 5,
                                    "a spinning thread uses the processor while we look")
        // The same sampler, asked directly, names the main thread's own id.
        let direct = sampler?.sample()
        XCTAssertEqual(direct?.threadID, mainThreadID(),
                       "the port must be the main thread's, not the watchdog's")
    }

    func testTheSampleOfABusyMainThreadNamesTheMainThreadWhenTakenByAnotherThread() {
        // The watchdog's own view, reproduced: the sampler is built on main and
        // used from a thread of ours.
        guard let sampler = MainThreadSampler.forCurrentThreadIfMain() else { return XCTFail("not on main") }
        let sampled = expectation(description: "sampled")
        var result: MainThreadSample?
        let helper = Foundation.Thread {
            result = sampler.sample()
            sampled.fulfill()
        }
        helper.start()
        wait(for: [sampled], timeout: 5)
        XCTAssertEqual(result?.threadID, mainThreadID())
        XCTAssertNotEqual(result?.threadID, 0)
    }

    func testASuspendedMainThreadShowsItsSuspendCount() {
        let reporter = RecordingStallReporter()
        guard let sampler = MainThreadSampler.forCurrentThreadIfMain() else { return XCTFail("not on main") }
        let port = sampler.port
        makeProbe(reporter: reporter).start()
        spinMainRunLoop(0.3)

        // A thread of ours suspends main once main waits on a semaphore (so it
        // holds no lock), keeps it suspended until the report is filed (or 15 s
        // pass), and resumes it. While main is suspended it calls nothing but
        // usleep, the reporter's own lock and thread_resume: anything that
        // allocates could wait for a lock main held when it stopped.
        let ready = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        let look = MainThreadSampler(port: port, looks: 1, gap: 0)
        let suspender = Foundation.Thread {
            ready.wait()
            // Main is on its way to `resumed.wait`: suspend it once it is
            // parked there, not after a fixed time.
            var polled = 0
            while look.sample().runState != .waiting && polled < 15_000 {
                usleep(1_000)
                polled += 1
            }
            thread_suspend(port)
            var waited = 0
            while reporter.count == 0 && waited < 15_000 {
                usleep(10_000)
                waited += 10
            }
            thread_resume(port)
            resumed.signal()
        }
        suspender.start()
        ready.signal()
        resumed.wait()

        let report = reporter.reports.first
        XCTAssertNotNil(report, "a suspended main thread must still be reported, and the watchdog must not hang on it")
        XCTAssertGreaterThanOrEqual(report?.suspendCount ?? 0, 1)
        XCTAssertNotEqual(report?.runState, .running)
    }

    func testADebuggedProcessReportsNothing() {
        let reporter = RecordingStallReporter()
        let asked = StallTestCounter()
        let probe = makeProbe(reporter: reporter, traced: { asked.increment(); return true })
        probe.start()
        spinMainRunLoop(0.3)

        // Held until the stall reaches the debugger check.
        let deadline = MainThreadStallProbe.systemUptime() + 15
        while asked.value == 0 && MainThreadStallProbe.systemUptime() < deadline { usleep(2_000) }

        answerUntilTheEpisodeEnds(probe)
        XCTAssertGreaterThan(asked.value, 0, "control: the stall reached the debugger check")
        XCTAssertEqual(reporter.count, 0, "a debugger stops the main thread on purpose")
    }

    func testAModeReadThatNeverReturnsStillGivesAReportAndTheWatchdogKeepsGoing() {
        let forever = DispatchSemaphore(value: 0)
        var reader = RunLoopModeReader(timeout: 0.3)
        reader.copyCurrentMode = { forever.wait(); return nil }
        let reporter = RecordingStallReporter()
        let probe = makeProbe(reporter: reporter, modeReader: reader)
        probe.start()
        spinMainRunLoop(0.3)

        XCTAssertTrue(reporter.waitForNextReport(), "the stall was never reported")

        forever.signal()
        XCTAssertEqual(reporter.reports.first?.runLoopMode, .unreadable)
        XCTAssertTrue(probe.isAlive)
        probe.stop()
        waitSpinning(limit: 3) { !probe.isAlive }
        XCTAssertFalse(probe.isAlive, "the watchdog did not end: it is stuck on the abandoned read")
    }

    func testStartingTwiceMakesOneWatchdogAndAnotherThreadCannotStartOne() {
        let probe = makeProbe(reporter: RecordingStallReporter())
        let elsewhere = expectation(description: "started elsewhere")
        Foundation.Thread {
            probe.start()
            elsewhere.fulfill()
        }.start()
        wait(for: [elsewhere], timeout: 5)
        XCTAssertFalse(probe.isRunning, "only the main thread's port means anything")

        probe.start()
        probe.start()
        XCTAssertTrue(probe.isRunning)
        probe.stop()
        waitSpinning(limit: 3) { !probe.isAlive }
        XCTAssertFalse(probe.isAlive, "the watchdog thread did not leave its loop")
    }

    func testOnceBothSlotsAreSpentAStallIsNotEvenLookedAt() {
        // The first stall is seen in menu tracking, the second in no mode; the
        // third must cost no looks and no run-loop read. A longer threshold
        // than the other tests: a stray stall (main starved while it should be
        // answering) would take a slot this test counts on.
        let threshold: TimeInterval = 1
        let reads = PhasedModeReads()
        var reader = RunLoopModeReader(timeout: 5)
        reader.copyCurrentMode = { reads.read() }
        let reporter = RecordingStallReporter()
        let probe = makeProbe(reporter: reporter, threshold: threshold, modeReader: reader)
        probe.start()
        answerUntilTheEpisodeEnds(probe)

        // 1 and 2: main parks until the report is filed, so the looks find it
        // waiting and the first stall is the explained one.
        reads.phase = 1
        XCTAssertTrue(reporter.waitForNextReport(), "the menu-tracking stall was never reported")
        answerUntilTheEpisodeEnds(probe)

        reads.phase = 2
        XCTAssertTrue(reporter.waitForNextReport(), "the second stall was never reported")
        answerUntilTheEpisodeEnds(probe)

        // 3: nothing to wait for (that is the point), so main is held until
        // the watchdog must have crossed the threshold and handled the stall.
        reads.phase = 3
        XCTAssertTrue(holdMain(until: probe, hasLooped: loopsToCrossAndHandle(threshold)),
                      "the watchdog stopped going round its loop")
        answerUntilTheEpisodeEnds(probe)

        XCTAssertEqual(reporter.reports.map(\.explained), [true, false])
        XCTAssertEqual(reads.readsByPhase, [1: 1, 2: 1],
                       "the third stall was looked at although both slots were spent")
    }

    func testAMachInfoCallForAnUnreadableThreadGivesAnUnknownStateNotACrash() {
        let sampler = MainThreadSampler(port: mach_port_t(MACH_PORT_NULL), looks: 2, gap: 0.01)
        let sample = sampler.sample()
        XCTAssertEqual(sample.runState, .unknown)
        XCTAssertEqual(sample.threadID, 0)
    }

    func testTheTracedCheckAnswersWithoutCrashing() {
        // Not asserted either way: it is true under a debugger.
        _ = MainThreadStallProbe.processIsBeingTraced()
    }
}

// MARK: - Wiring and promises

final class MainThreadStallProbeWiringTests: XCTestCase {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // CLIPulseCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // CLIPulseCore
        .deletingLastPathComponent()   // CLI Pulse Bar
        .deletingLastPathComponent()   // repository root

    private func read(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relative), encoding: .utf8)
    }

    /// The probe starts where Sentry does, behind the same capability: the QA
    /// and quarantine environments (whose `allowsTelemetry` is false, pinned
    /// in `CLIPulseRuntimeEnvironmentTests`) never start it.
    func testTheProbeStartsInsideTheTelemetryBlockOfTheMacApp() throws {
        let app = try read("CLI Pulse Bar/CLI Pulse Bar/CLIPulseBarApp.swift")
        let block = try NSRegularExpression(
            pattern: #"if runtimeEnvironment\.capabilities\.allowsTelemetry \{[^{}]*MainThreadStallProbe\.shared\.start\(\)[^{}]*\}"#)
        XCTAssertNotNil(block.firstMatch(in: app, range: NSRange(app.startIndex..., in: app)),
                        "MainThreadStallProbe.shared.start() must be inside `if …allowsTelemetry { … }`")
        XCTAssertEqual(app.components(separatedBy: "MainThreadStallProbe.shared.start()").count - 1, 1)
    }

    func testPrivacyNamesTheStallReportAndWhatItCarries() throws {
        let policy = try read("PRIVACY.md").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        for claim in [
            "Since v1.60 the Mac app also sends an error report when its main thread has not answered for ten seconds, at most two a launch",
            "a fixed word for what the main thread was doing",
            "a fixed word for the kind of event loop it was in",
            "It has no stack trace and no breadcrumbs",
        ] {
            XCTAssertTrue(policy.contains(claim), "PRIVACY.md no longer says \"\(claim)\"")
        }
        // Every tag the event carries has its words in the policy.
        for word in ["default", "event_tracking", "modal_panel", "unreadable"] {
            XCTAssertTrue(policy.contains("`\(word)`"), "PRIVACY.md does not list the mode word \(word)")
        }
    }
}
#endif
