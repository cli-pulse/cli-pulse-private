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
//      debugger holds, and a run-loop read that never returns. Margins are
//      generous and nothing asserts an upper bound on a time.
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

private final class RecordingStallReporter: StallReporter, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [StallReport] = []
    var reports: [StallReport] { lock.lock(); defer { lock.unlock() }; return stored }
    func report(_ report: StallReport) { lock.lock(); stored.append(report); lock.unlock() }
}

final class MainThreadStallProbeTests: XCTestCase {

    private var probes: [MainThreadStallProbe] = []

    override func tearDown() {
        probes.forEach { $0.stop() }
        probes = []
        super.tearDown()
    }

    /// Short thresholds so a test stalls the main thread for about two
    /// seconds, and a slack so wide that a slow runner does not make the
    /// watchdog look asleep.
    private func makeProbe(
        reporter: RecordingStallReporter,
        threshold: TimeInterval = 0.5,
        traced: Bool = false,
        modeReader: RunLoopModeReader = RunLoopModeReader(timeout: 1)
    ) -> MainThreadStallProbe {
        var dependencies = MainThreadStallProbe.Dependencies()
        dependencies.reporter = reporter
        dependencies.channel = { .devid }
        dependencies.isBeingTraced = { traced }
        dependencies.modeReader = modeReader
        let probe = MainThreadStallProbe(
            configuration: .init(pingInterval: 0.1, threshold: threshold, oversleepSlack: 30),
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

    private func busySpin(_ seconds: TimeInterval) {
        let end = MainThreadStallProbe.systemUptime() + seconds
        var x = 0.0
        while MainThreadStallProbe.systemUptime() < end { x += sin(x) + 1 }
        XCTAssertFalse(x.isNaN)
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
        XCTAssertEqual(reporter.reports.count, 0, "nothing is reported while main answers")

        Thread.sleep(forTimeInterval: 2)

        waitSpinning { !reporter.reports.isEmpty }
        spinMainRunLoop(0.5)   // an episode ends with an answer; nothing more may come
        XCTAssertEqual(reporter.reports.count, 1)
        let report = try? XCTUnwrap(reporter.reports.first)
        XCTAssertEqual(report?.runState, .waiting)
        XCTAssertEqual(report?.suspendCount, 0)
        XCTAssertGreaterThanOrEqual(report?.stall ?? 0, 0.5)
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
        XCTAssertEqual(reporter.reports.count, 0)
    }

    func testABusyMainThreadIsRunningAndTheThreadSampledIsTheMainThread() {
        let reporter = RecordingStallReporter()
        let sampler = MainThreadSampler.forCurrentThreadIfMain()
        XCTAssertNotNil(sampler)
        makeProbe(reporter: reporter).start()
        spinMainRunLoop(0.3)

        busySpin(1.5)

        waitSpinning { !reporter.reports.isEmpty }
        let report = reporter.reports.first
        XCTAssertEqual(report?.runState, .running)
        XCTAssertGreaterThanOrEqual(report?.cpuMilliseconds ?? 0, 20,
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

        // A thread of ours suspends main while main waits on a semaphore (so it
        // holds no lock), keeps it suspended, and resumes it. After the
        // suspension it calls nothing but usleep and thread_resume: anything
        // that allocates could wait for a lock main held when it stopped.
        let ready = DispatchSemaphore(value: 0)
        let resumed = DispatchSemaphore(value: 0)
        let suspender = Foundation.Thread {
            ready.wait()
            usleep(300_000)               // main is parked in `resumed.wait` by now
            thread_suspend(port)
            usleep(2_500_000)
            thread_resume(port)
            resumed.signal()
        }
        suspender.start()
        ready.signal()
        resumed.wait()

        waitSpinning { !reporter.reports.isEmpty }
        let report = reporter.reports.first
        XCTAssertNotNil(report, "a suspended main thread must still be reported, and the watchdog must not hang on it")
        XCTAssertGreaterThanOrEqual(report?.suspendCount ?? 0, 1)
        XCTAssertNotEqual(report?.runState, .running)
    }

    func testADebuggedProcessReportsNothing() {
        let reporter = RecordingStallReporter()
        let asked = NSLock()
        var askedCount = 0
        var dependencies = MainThreadStallProbe.Dependencies()
        dependencies.reporter = reporter
        dependencies.isBeingTraced = { asked.lock(); askedCount += 1; asked.unlock(); return true }
        let probe = MainThreadStallProbe(
            configuration: .init(pingInterval: 0.1, threshold: 0.5, oversleepSlack: 30),
            dependencies: dependencies)
        probes.append(probe)
        probe.start()
        spinMainRunLoop(0.3)

        Thread.sleep(forTimeInterval: 1.5)

        spinMainRunLoop(0.6)
        asked.lock(); let count = askedCount; asked.unlock()
        XCTAssertGreaterThan(count, 0, "control: the stall reached the debugger check")
        XCTAssertEqual(reporter.reports.count, 0, "a debugger stops the main thread on purpose")
    }

    func testAModeReadThatNeverReturnsStillGivesAReportAndTheWatchdogKeepsGoing() {
        let forever = DispatchSemaphore(value: 0)
        var reader = RunLoopModeReader(timeout: 0.3)
        reader.copyCurrentMode = { forever.wait(); return nil }
        let reporter = RecordingStallReporter()
        let probe = makeProbe(reporter: reporter, modeReader: reader)
        probe.start()
        spinMainRunLoop(0.3)

        Thread.sleep(forTimeInterval: 2)

        waitSpinning { !reporter.reports.isEmpty }
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
        // third must cost no looks and no run-loop read.
        let reads = NSLock()
        var readCount = 0
        var reader = RunLoopModeReader(timeout: 5)
        reader.copyCurrentMode = {
            reads.lock(); readCount += 1; let n = readCount; reads.unlock()
            return n == 1 ? "NSEventTrackingRunLoopMode" : nil
        }
        let reporter = RecordingStallReporter()
        makeProbe(reporter: reporter, threshold: 0.3, modeReader: reader).start()
        for _ in 0..<3 {
            spinMainRunLoop(0.3)
            Thread.sleep(forTimeInterval: 1.0)
        }
        spinMainRunLoop(0.3)
        reads.lock(); let total = readCount; reads.unlock()
        XCTAssertEqual(reporter.reports.map(\.explained), [true, false])
        XCTAssertEqual(total, 2, "the third stall was looked at although both slots were spent")
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
