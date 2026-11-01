// 1.61 (B3): a deferred session restore tries again when the app comes to the
// front or the network comes back, not only at its next backoff tick.
//
// Each try of the restore is one `GET /auth/v1/user`, so the stub's request
// log counts tries. The network monitor and the clock are fakes the test
// drives; the backoff's own sleeping retry is real, so each test checks that
// the try it counts is the trigger's (`deferredSessionRestoreRetryTask`), not
// that retry's.

import Foundation
import XCTest
#if os(macOS)
import AppKit
#endif
@testable import CLIPulseCore

@MainActor
final class DeferredSessionRestoreTriggerTests: XCTestCase {

    private static let userPath = "/auth/v1/user"

    override func setUp() {
        super.setUp()
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
    }

    override func tearDown() {
        SessionRestoreStub.reset()
        KeychainHelper.inMemoryStoreForTesting = [:]
        super.tearDown()
    }

    // MARK: - Each trigger

    func test_the_network_coming_back_tries_at_once() async throws {
        let (state, network, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 1, "the launch try")
        XCTAssertTrue(network.isWatching, "watched while deferred")

        clock.now += 6                           // past the spacing
        network.comeBack()
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask, "the network started a try")
        await retry.value

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2, "tried at once")
        // The backoff counts on: still offline, the next try is a step further.
        XCTAssertEqual(state.deferredSessionRestoreAttempts, 2)
        XCTAssertNotNil(state.deferredSessionRestoreTask)
        XCTAssertEqual(state.deferredSessionRestoreDueAt, clock.now + AppState.deferredSessionRestoreDelay(attempt: 2))
    }

    #if os(macOS)
    func test_the_mac_app_becoming_active_tries_at_once() async throws {
        let (state, _, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }

        clock.now += 6
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        await Self.until(seconds: 1) { state.deferredSessionRestoreRetryTask != nil }
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask, "the activation started a try")
        await retry.value

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2)
    }

    func test_the_menu_opening_tries_at_once() async throws {
        let (state, _, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }

        clock.now += 6
        state.notePopoverActivated()
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask, "the menu started a try")
        await retry.value

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2)
    }
    #endif

    /// The iPhone's trigger is the scene becoming active, in the app target
    /// (which `swift test` does not build): pinned to the call it makes.
    func test_the_iphone_scene_becoming_active_calls_the_retry() throws {
        let app = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CLI Pulse Bar iOS/CLIPulseApp_iOS.swift")
        let source = try String(contentsOf: app, encoding: .utf8)
        let active = try XCTUnwrap(source.range(of: "if phase == .active {"), "the scene-phase hook")
        let block = source[active.upperBound...].prefix { $0 != "}" }
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
        XCTAssertTrue(block.contains("appState.retryDeferredSessionRestoreNow()"),
                      "the iPhone retries a deferred restore when its scene becomes active")
    }

    func test_a_restored_session_after_a_trigger_ends_the_watch() async throws {
        let (state, network, clock) = await Self.deferredState()
        Self.answerSignedIn()

        clock.now += 6
        network.comeBack()
        let retry = try XCTUnwrap(state.deferredSessionRestoreRetryTask, "the network started a try")
        await retry.value
        defer { state.stopRefreshLoop() }

        XCTAssertTrue(state.isAuthenticated, "the try the network set off restored the session")
        XCTAssertNil(state.deferredSessionRestoreTask)
        XCTAssertEqual(state.deferredSessionRestoreAttempts, 0)
        XCTAssertFalse(network.isWatching, "nothing deferred, nothing watched")
    }

    // MARK: - No storms

    /// Triggers while a try is out are noted, not run: however many, they
    /// make one more try, as soon as the spacing allows after that one fails.
    func test_triggers_while_a_try_is_out_coalesce_into_one() async {
        let (state, network, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }
        SessionRestoreStub.respond { _ in .held(503, "{}") }

        clock.now += 6
        network.comeBack()
        await Self.until { SessionRestoreStub.count(Self.userPath) == 2 }
        XCTAssertTrue(state.deferredSessionRestoreInFlight)

        clock.now += 2                           // news, not the same moment told twice
        network.comeBack()
        state.retryDeferredSessionRestoreNow()
        state.retryDeferredSessionRestoreNow()
        await Self.yield()
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2, "no second try while one is out")

        SessionRestoreStub.releaseHeld()         // the try fails: 503
        await state.deferredSessionRestoreRetryTask?.value
        XCTAssertFalse(state.deferredSessionRestoreInFlight)
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2)
        // One more, as soon as the spacing allows (5 s after the last went
        // out, 2 s ago), not a whole backoff step (10 s) away.
        XCTAssertEqual(state.deferredSessionRestoreDueAt, clock.now + 3)
    }

    /// On a Mac, opening the menu also makes the app active: one moment, told
    /// twice within a second. The second is not a reason for a follow-up.
    func test_the_same_moment_told_twice_is_one_trigger() async {
        let (state, network, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }
        SessionRestoreStub.respond { _ in .held(503, "{}") }

        clock.now += 6
        state.retryDeferredSessionRestoreNow()   // the menu opening
        await Self.until { SessionRestoreStub.count(Self.userPath) == 2 }
        network.comeBack()                       // the app becoming active, same moment
        SessionRestoreStub.releaseHeld()
        await state.deferredSessionRestoreRetryTask?.value

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2)
        XCTAssertEqual(state.deferredSessionRestoreDueAt,
                       clock.now + AppState.deferredSessionRestoreDelay(attempt: 2), "the backoff, no follow-up")
    }

    /// Two tries are never closer than the spacing. A trigger too soon after
    /// the last brings the sleeping retry forward to when it allows, and
    /// never later than it was.
    func test_a_trigger_inside_the_spacing_brings_the_retry_forward_instead() async {
        let (state, network, clock) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }

        clock.now += 6
        network.comeBack()                       // try 2, fails: next due in 10 s
        await state.deferredSessionRestoreRetryTask?.value
        let retry = state.deferredSessionRestoreRetryTask
        XCTAssertEqual(state.deferredSessionRestoreDueAt, clock.now + 10)

        clock.now += 2
        network.comeBack()                       // 2 s after try 2 went out
        await Self.yield()
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 2, "not inside the spacing")
        XCTAssertEqual(state.deferredSessionRestoreRetryTask, retry, "no try started")
        XCTAssertEqual(state.deferredSessionRestoreDueAt, clock.now + 3, "brought forward to the spacing")

        clock.now += 1
        let sleeping = state.deferredSessionRestoreTask
        network.comeBack()                       // still inside; due is already that soon
        XCTAssertEqual(state.deferredSessionRestoreTask, sleeping, "not re-armed")
        XCTAssertEqual(state.deferredSessionRestoreDueAt, clock.now + 2)
    }

    /// The first try's spacing counts from the launch's own try.
    func test_a_trigger_right_after_the_launch_try_does_not_try_again() async {
        let (state, network, _) = await Self.deferredState()
        defer { state.cancelDeferredSessionRestore() }

        network.comeBack()
        state.retryDeferredSessionRestoreNow()
        await Self.yield()

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 1)
        XCTAssertNil(state.deferredSessionRestoreRetryTask)
    }

    // MARK: - Nothing deferred

    func test_a_trigger_with_nothing_deferred_does_nothing() async {
        let (state, network, _) = Self.makeState()
        network.comeBack()
        state.retryDeferredSessionRestoreNow()
        await Self.yield()

        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 0)
        XCTAssertNil(state.deferredSessionRestoreRetryTask)
        XCTAssertFalse(network.didStart, "not watched without a deferred restore")
    }

    func test_a_sign_out_ends_the_watch() async {
        let (state, network, clock) = await Self.deferredState()

        state.signOut()
        XCTAssertFalse(network.isWatching)

        clock.now += 6
        network.comeBack()
        state.retryDeferredSessionRestoreNow()
        #if os(macOS)
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        #endif
        await Self.yield()
        XCTAssertEqual(SessionRestoreStub.count(Self.userPath), 1)
        XCTAssertNil(state.deferredSessionRestoreRetryTask)
    }

    // MARK: - The network detector

    func test_only_a_step_from_unsatisfied_to_satisfied_is_a_return() {
        func returns(_ updates: [Bool]) -> Int {
            var detector = NetworkReturnDetector()
            return updates.filter { detector.update(satisfied: $0) }.count
        }
        XCTAssertEqual(returns([true]), 0, "the state the watch starts in is not a return")
        XCTAssertEqual(returns([false, true]), 1)
        XCTAssertEqual(returns([true, true, true]), 0, "a change between two working paths")
        XCTAssertEqual(returns([true, false, true]), 1)
        XCTAssertEqual(returns([false, false, true, true]), 1)
        XCTAssertEqual(returns([false, true, false, true]), 2)
    }

    // MARK: - Helpers

    final class FakeNetwork: NetworkReturnWatching {
        private var onReturn: (@MainActor () -> Void)?
        private(set) var didStart = false
        private(set) var isWatching = false
        func start(onReturn: @escaping @MainActor () -> Void) {
            self.onReturn = onReturn; didStart = true; isWatching = true
        }
        func cancel() { isWatching = false }
        @MainActor func comeBack() { if isWatching { onReturn?() } }
    }

    final class Clock { var now: TimeInterval = 1_000 }

    private static func makeState() -> (AppState, FakeNetwork, Clock) {
        let api = APIClient(supabaseURL: "https://stub.cli-pulse.test", supabaseAnonKey: "anon",
                            session: SessionRestoreStub.session())
        let state = AppState(
            runtimeEnvironment: .resolveForTesting(infoDictionary: [:], environment: [:]),
            defaults: UploadOutcomeTests.freshDefaults(),
            api: api,
            performLaunchSetup: false)
        let network = FakeNetwork()
        let clock = Clock()
        state.makeNetworkReturnMonitor = { network }
        state.deferredSessionRestoreClock = { clock.now }
        return (state, network, clock)
    }

    /// A cold launch whose restore found no network: deferred, the retry
    /// sleeping, the triggers watched. Every request still fails offline.
    private static func deferredState() async -> (AppState, FakeNetwork, Clock) {
        SessionRestoreStub.respond { _ in .fail(URLError(.notConnectedToInternet)) }
        let (state, network, clock) = makeState()
        AppState.persistAuthTokens(access: "access-old", refresh: "refresh-1")
        await state.restoreSession()
        XCTAssertFalse(state.isAuthenticated)
        XCTAssertNotNil(state.deferredSessionRestoreTask, "deferred")
        XCTAssertEqual(state.deferredSessionRestoreAttempts, 1)
        return (state, network, clock)
    }

    private static func answerSignedIn() {
        SessionRestoreStub.respond { request in
            switch request.url?.path {
            case "/auth/v1/user":
                return .status(200, #"{"id":"00000000-0000-0000-0000-000000000001","email":"someone@example.test"}"#)
            case "/rest/v1/profiles":
                return .status(200, #"[{"paired":false,"name":"Someone","email":"someone@example.test"}]"#)
            default:
                return .fail(URLError(.notConnectedToInternet))
            }
        }
    }

    private static func yield() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        for _ in 0..<20 { await Task.yield() }
    }

    private static func until(seconds: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
