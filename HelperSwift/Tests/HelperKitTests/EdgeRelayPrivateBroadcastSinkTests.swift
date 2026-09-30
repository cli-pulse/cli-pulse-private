import XCTest
@testable import HelperKit
import Foundation

/// Pins the HTTP wire shape and the delivery behaviour of
/// `EdgeRelayPrivateBroadcastSink`. The first cut of that type had NO test
/// past its `guard channel.hasPrefix("pterm:")` line — every property below
/// was unverified, including two that turned out to be wrong.
///
/// Requests go to `RelayStub` (bottom of this file), not the shared
/// `InterceptProtocol`; its comment says why.
final class EdgeRelayPrivateBroadcastSinkTests: XCTestCase {

    /// Records every relay request, in order, and tracks how many were in
    /// flight at once.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [[String: Any]] = []
        private var _urls: [String] = []
        private var _headers: [[String: String]] = []
        private var inFlight = 0
        private var _maxInFlight = 0
        private var holdFirst = false
        private var heldFirst: (@Sendable () -> Void)?
        var status = 200

        var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
        var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _headers }
        var maxInFlight: Int { lock.lock(); defer { lock.unlock() }; return _maxInFlight }
        var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return inFlight == 0 }

        /// All data_b64 values across all requests, flattened in send order.
        var flatChunks: [String] {
            bodies.flatMap { ($0["chunks"] as? [[String: Any]] ?? []).compactMap { $0["data_b64"] as? String } }
        }

        /// Keep the FIRST request's response open until `releaseFirstRequest()`,
        /// so a test acts while a POST is definitely in flight instead of
        /// guessing how long one takes. Later requests are answered at once, so
        /// a sink that wrongly overlaps POSTs or keeps sending after a purge
        /// shows up as extra requests, not as a hang.
        func holdFirstRequest() {
            lock.lock(); holdFirst = true; lock.unlock()
        }

        func releaseFirstRequest() {
            lock.lock()
            let finish = heldFirst
            heldFirst = nil
            holdFirst = false
            lock.unlock()
            finish?()
        }

        func install() {
            RelayStub.handler = { [self] req, body, respond in
                lock.lock()
                let isFirst = _urls.isEmpty
                inFlight += 1
                _maxInFlight = max(_maxInFlight, inFlight)
                _urls.append(req.url?.absoluteString ?? "")
                _headers.append(req.allHTTPHeaderFields ?? [:])
                _bodies.append(body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:])
                let st = status
                let finish: @Sendable () -> Void = { [self] in
                    lock.lock(); inFlight -= 1; lock.unlock()
                    respond(st)
                }
                if isFirst && holdFirst {
                    heldFirst = finish
                    lock.unlock()
                    return
                }
                lock.unlock()
                finish()
            }
        }
    }

    private var rec: Recorder!

    override func setUp() {
        super.setUp()
        rec = Recorder()
        rec.install()
    }

    override func tearDown() {
        // A test that failed before releasing must not leave a response open.
        rec.releaseFirstRequest()
        RelayStub.handler = nil
        rec = nil
        super.tearDown()
    }

    private static let cloud = HelperConfigStore.CloudConfig(
        deviceId: "11111111-2222-3333-4444-555555555555",
        helperSecret: "stub-secret",
        supabaseURL: "https://example.supabase.co",
        supabaseAnonKey: "anon-key"
    )

    private static func relaySession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RelayStub.self]
        return URLSession(configuration: cfg)
    }

    private func makeSink(
        coalesce: Duration = .milliseconds(1),
        denialBackoff: Duration = .milliseconds(80),
        maxBatchCount: Int = 64,
        cloud: HelperConfigStore.CloudConfig? = nil
    ) -> EdgeRelayPrivateBroadcastSink {
        let c = cloud ?? Self.cloud
        return EdgeRelayPrivateBroadcastSink(
            configProvider: { c },
            // Far above the 2.5 s default, so a response a test holds open
            // cannot time out however slow the runner is.
            requestTimeout: 60,
            coalesceWindow: coalesce,
            maxBatchCount: maxBatchCount,
            denialBackoff: denialBackoff,
            session: Self.relaySession())
    }

    private func publish(_ sink: EdgeRelayPrivateBroadcastSink, _ sid: String, _ text: String) async {
        try? await sink.publish(
            sessionId: sid, channel: "pterm:\(sid)", event: "stdout",
            redactedBytes: Data(text.utf8))
    }

    /// Polls until `condition` holds or `timeout` passes; returns whether it held.
    ///
    /// Tests here wait for something the sink did instead of sleeping for a
    /// guess at how long it takes. A sleep that is generous on a laptop is
    /// short on a loaded CI runner; the deadline only bounds a real failure.
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
        return true
    }

    // MARK: - wire shape

    func test_postsToTheRelayEndpointWithGatewayAuthAndTheExpectedBody() async {
        let sink = makeSink()
        await publish(sink, "sid-1", "hello")
        await sink.flushNow()

        XCTAssertEqual(rec.urls.count, 1)
        XCTAssertEqual(rec.urls.first,
                       "https://example.supabase.co/functions/v1/broadcast-terminal")
        let h = rec.headers.first ?? [:]
        XCTAssertEqual(h["apikey"], "anon-key")
        XCTAssertEqual(h["Authorization"], "Bearer anon-key")

        let b = rec.bodies.first ?? [:]
        XCTAssertEqual(b["device_id"] as? String, Self.cloud.deviceId)
        XCTAssertEqual(b["helper_secret"] as? String, "stub-secret")
        XCTAssertEqual(b["session_id"] as? String, "sid-1")
        let chunks = b["chunks"] as? [[String: Any]] ?? []
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first?["event"] as? String, "stdout")
        XCTAssertEqual(chunks.first?["data_b64"] as? String, Data("hello".utf8).base64EncodedString())
        // The topic is NOT caller-supplied — the relay derives it from the
        // session id it authorized. Sending one would be a hole.
        XCTAssertNil(b["topic"])
    }

    func test_unpairedNeverReachesTheNetwork() async {
        let sink = makeSink(cloud: .init(deviceId: "", helperSecret: "", supabaseURL: "", supabaseAnonKey: ""))
        await publish(sink, "sid-1", "x")
        await sink.flushNow()
        XCTAssertTrue(rec.urls.isEmpty)
    }

    func test_coalescesMultipleChunksIntoOneRequest() async {
        let sink = makeSink(coalesce: .milliseconds(50))
        for i in 1...5 { await publish(sink, "sid-1", "c\(i)") }
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 1, "five chunks in one window must be one POST")
        XCTAssertEqual(rec.flatChunks.count, 5)
    }

    // MARK: - ordering (the corruption case)

    func test_onlyOneRequestPerSessionIsEverInFlight() async {
        // The actor is REENTRANT across await. Without the single-flight latch
        // a chunk arriving during an in-flight POST arms a second flush that
        // issues a CONCURRENT POST — and out-of-order terminal output is
        // corruption, not lateness.
        rec.holdFirstRequest()
        let sink = makeSink(coalesce: .milliseconds(1))
        await publish(sink, "sid-1", "c1")
        let c1InFlight = await waitUntil { rec.urls.count == 1 }
        XCTAssertTrue(c1InFlight, "the first POST never reached the relay")
        // c1's POST is held open, so every flush below, the timer's and the
        // direct ones, starts while it is in flight. One that sent a second
        // POST now would make maxInFlight 2.
        for i in 2...12 {
            await publish(sink, "sid-1", "c\(i)")
            await sink.flushNow()
        }
        rec.releaseFirstRequest()
        let drained = await waitUntil { rec.flatChunks.count == 12 && rec.isIdle }
        XCTAssertTrue(drained, "the sink never delivered all 12 chunks")
        XCTAssertEqual(rec.maxInFlight, 1,
                       "overlapping POSTs for one session can reorder terminal output")
        let expected = (1...12).map { Data("c\($0)".utf8).base64EncodedString() }
        XCTAssertEqual(rec.flatChunks, expected, "chunks must arrive in submit order")
    }

    func test_noChunkIsStrandedWhenItArrivesDuringAnInFlightPost() async {
        // A relay slower than the coalescing window. "second" arrives while
        // the first POST is in flight, and the timer it arms fires while that
        // POST is STILL in flight, so the latch turns its flush away. Nothing
        // else will publish, so the sink itself has to send "second" once the
        // POST returns, or it sits in `pending` indefinitely.
        rec.holdFirstRequest()
        let sink = makeSink(coalesce: .milliseconds(1))
        await publish(sink, "sid-1", "first")
        let firstInFlight = await waitUntil { rec.urls.count == 1 }
        XCTAssertTrue(firstInFlight, "the first POST never reached the relay")
        await publish(sink, "sid-1", "second")
        // Keep the first POST open for 100 coalescing windows, so the timer
        // "second" armed fires while it is in flight. Released at once, that
        // timer usually fires after the POST returns and delivers "second"
        // itself, so a sink that strands the chunk would still pass.
        // This sleep cannot fail the test: a runner that delays the timer
        // past the release only makes the test check an easier case.
        try? await Task.sleep(for: .milliseconds(100))
        rec.releaseFirstRequest()
        // No flushNow: delivering "second" is the sink's own job. A flushNow
        // here would send it on the test's behalf and hide a stranded chunk.
        _ = await waitUntil { rec.flatChunks.count >= 2 }
        XCTAssertEqual(rec.flatChunks, [
            Data("first".utf8).base64EncodedString(),
            Data("second".utf8).base64EncodedString(),
        ])
    }

    // MARK: - denial

    func test_403SuppressesTheSessionButTheSuppressionEXPIRES() async {
        // The denial is user-reversible: an attached session is authorized only
        // after the user opts in, and Remote Control can be toggled. A
        // permanent latch would kill the mirror for exactly the flow this
        // producer exists to serve.
        rec.status = 403
        let sink = makeSink(coalesce: .milliseconds(1), denialBackoff: .milliseconds(60))
        await publish(sink, "sid-1", "a")
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 1)

        // Suppressed: publish now throws and nothing is sent.
        do {
            try await sink.publish(sessionId: "sid-1", channel: "pterm:sid-1",
                                   event: "stdout", redactedBytes: Data("b".utf8))
            XCTFail("expected .denied while suppressed")
        } catch let e as EdgeRelayPrivateBroadcastSink.SinkError {
            XCTAssertEqual(e, .denied)
        } catch { XCTFail("wrong error: \(error)") }
        XCTAssertEqual(rec.urls.count, 1)

        // After the backoff, it retries — the user may have opted in by now.
        try? await Task.sleep(for: .milliseconds(90))
        rec.status = 200
        await publish(sink, "sid-1", "c")
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 2, "suppression must expire, not latch forever")
    }

    func test_401IsNotAPerSessionDenial() async {
        // Only the gateway can emit 401 (wrong/rotated anon key) — a GLOBAL
        // config fault, identical for every session. Suppressing per-session on
        // it would mark each session denied in turn while the real fault went
        // unreported.
        rec.status = 401
        let sink = makeSink(coalesce: .milliseconds(1))
        await publish(sink, "sid-1", "a")
        await sink.flushNow()
        // Not suppressed: the next publish still tries.
        await publish(sink, "sid-1", "b")
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 2)
    }

    func test_5xxDoesNotSuppressTheSession() async {
        rec.status = 500
        let sink = makeSink(coalesce: .milliseconds(1))
        await publish(sink, "sid-1", "a")
        await sink.flushNow()
        await publish(sink, "sid-1", "b")
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 2, "infra failure must not latch a healthy session")
    }

    func test_countersRecordOutcomesSoADarkShipIsEvaluable() async {
        let sink = makeSink(coalesce: .milliseconds(1), denialBackoff: .seconds(60))
        await publish(sink, "sid-1", "a")
        await sink.flushNow()
        var st = await sink.stats()
        XCTAssertEqual(st.sent, 1); XCTAssertEqual(st.failed, 0); XCTAssertEqual(st.suppressed, 0)

        rec.status = 500
        await publish(sink, "sid-2", "b")
        await sink.flushNow()
        st = await sink.stats()
        XCTAssertEqual(st.sent, 1); XCTAssertEqual(st.failed, 1); XCTAssertEqual(st.suppressed, 0)

        rec.status = 403
        await publish(sink, "sid-3", "c")
        await sink.flushNow()
        st = await sink.stats()
        XCTAssertEqual(st.suppressed, 1, "a denial is a distinct outcome from a failure")
        XCTAssertEqual(st.failed, 1)
    }

    func test_aDenialStopsTheSessionsRemainingGroupsInTheSamePass() async {
        // The `break` that did this was lost when the permanent latch became an
        // expiring one. `isDenied` is checked once per session per pass, ABOVE
        // the group loop, so without it the sink re-POSTs and re-logs once per
        // group for a session it was just told it may not write to.
        rec.status = 403
        // maxBatchCount 1 => one group per chunk, so a missing break is visible
        // as extra requests.
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { Self.cloud },
            coalesceWindow: .milliseconds(1),
            maxBatchCount: 1,
            session: Self.relaySession())
        for i in 1...5 { await publish(sink, "sid-1", "c\(i)") }
        await sink.flushNow()
        XCTAssertEqual(rec.urls.count, 1,
                       "one denial must stop the remaining groups of the same pass")
        let st = await sink.stats()
        XCTAssertEqual(st.suppressed, 1, "and must be counted once, not once per group")
    }

    func test_pendingIsBoundedWhenTheRelayIsSLOW() async {
        // This buffer is the ONE queue the publisher's drop-oldest bound cannot
        // reach: `publish` returns as soon as it appends here, so the publisher
        // considers the chunk delivered.
        //
        // The state that matters is a SLOW relay, not a suppressed one. An
        // earlier version of this test set status 403 — dead setup, because a
        // suppressed session cannot grow at all (`publish` throws before the
        // append), and with a 60 s window no request was ever made so nothing
        // was ever suppressed either. It asserted the right number for no
        // reason.
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { Self.cloud },
            coalesceWindow: .seconds(60),   // never fires during the test
            maxPendingPerSession: 8,
            session: Self.relaySession())
        for i in 1...40 { await publish(sink, "sid-1", "c\(i)") }
        let st = await sink.stats()
        XCTAssertEqual(st.droppedForBackpressure, 32,
                       "excess must be dropped at the buffer, not accumulated")
    }

    func test_purgeStopsATailThatIsALREADYINFLIGHT() async {
        // THE case purge exists for, and the one the idle test below cannot
        // reach. `flush()` lifts the whole buffer into a local before its first
        // await, so clearing `pending` cannot reach a batch already in flight —
        // "whatever a slow relay was holding" is definitionally "already out of
        // pending". Measured before the fix: all 5 chunks POSTed after revoke.
        rec.holdFirstRequest()
        // One group per chunk => a visible tail. The window never fires: the
        // pass is started below, so it carries all five chunks however the
        // runner schedules the publishes.
        let sink = makeSink(coalesce: .seconds(60), maxBatchCount: 1)
        for i in 1...5 { await publish(sink, "sid-1", "c\(i)") }
        let pass = Task { await sink.flushNow() }
        let c1InFlight = await waitUntil { rec.urls.count == 1 }
        XCTAssertTrue(c1InFlight, "the first POST never reached the relay")
        // c1 is on the wire; c2...c5 are out of `pending` but not yet sent.
        await sink.purge(sessionId: "sid-1")
        rec.releaseFirstRequest()
        await pass.value
        XCTAssertEqual(
            rec.urls.count, 1,
            "a revoke must abandon the rest of the tail, not deliver it — got \(rec.urls.count) POSTs")
    }

    func test_purgeStopsEVERYSessionsTailNotJustTheFirstIterated() async {
        // The single-session test above passes even when the barrier is armed
        // AFTER a purge, because the first-iterated session is the one case a
        // late capture still protects — and which session that is, is
        // Dictionary iteration order. The global kill switch
        // (`revokeAllCloudShares`) is multi-session by definition, so this is
        // the shape that actually matters. Measured with the late capture:
        // 6 POSTs, 5 of them after both purges.
        rec.holdFirstRequest()
        // Started by hand for the same reason as above, and it matters more
        // here: a pass that caught only sid-1's first chunk would hold one
        // session, and the barrier would have nothing to protect.
        let sink = makeSink(coalesce: .seconds(60), maxBatchCount: 1)
        for i in 1...5 {
            await publish(sink, "sid-1", "a\(i)")
            await publish(sink, "sid-2", "b\(i)")
        }
        let pass = Task { await sink.flushNow() }
        let firstInFlight = await waitUntil { rec.urls.count == 1 }
        XCTAssertTrue(firstInFlight, "the first POST never reached the relay")
        // Exactly what revokeAllCloudShares' Task does.
        await sink.purge(sessionId: "sid-1")
        await sink.purge(sessionId: "sid-2")
        rec.releaseFirstRequest()
        await pass.value
        XCTAssertEqual(
            rec.urls.count, 1,
            "a global revoke must abandon EVERY session's tail, not just one — got \(rec.urls.count) POSTs")
    }

    func test_purgeDropsTheBufferedTailOnRevoke() async {
        let sink = makeSink(coalesce: .seconds(60))  // nothing flushes on its own
        for i in 1...5 { await publish(sink, "sid-1", "c\(i)") }
        await publish(sink, "sid-2", "keep")
        await sink.purge(sessionId: "sid-1")
        await sink.flushNow()
        XCTAssertEqual(rec.bodies.compactMap { $0["session_id"] as? String }, ["sid-2"],
                       "a revoked session's buffered tail must not be POSTed")
        XCTAssertEqual(rec.flatChunks, [Data("keep".utf8).base64EncodedString()])
    }

    func test_tailSnapshotEventSurvivesTheRelayContract() async {
        // The relay's allowlist rejected `tail_snapshot_result` wholesale with
        // 400, which also destroyed any stdout coalesced into the same batch.
        // Pin the event name the helper actually emits on this wire.
        let sink = makeSink(coalesce: .milliseconds(50))
        try? await sink.publish(sessionId: "sid-1", channel: "pterm:sid-1",
                                event: "tail_snapshot_result",
                                redactedBytes: Data("snap".utf8))
        await publish(sink, "sid-1", "live")
        await sink.flushNow()
        let events = (rec.bodies.first?["chunks"] as? [[String: Any]] ?? [])
            .compactMap { $0["event"] as? String }
        XCTAssertEqual(events, ["tail_snapshot_result", "stdout"])
    }

    func test_oneSessionsDenialDoesNotSuppressAnother() async {
        rec.status = 403
        let sink = makeSink(coalesce: .milliseconds(1), denialBackoff: .seconds(60))
        await publish(sink, "sid-1", "a")
        await sink.flushNow()
        rec.status = 200
        await publish(sink, "sid-2", "b")
        await sink.flushNow()
        XCTAssertEqual(rec.bodies.compactMap { $0["session_id"] as? String }, ["sid-1", "sid-2"])
    }
}

/// Stands in for the relay without serializing requests.
///
/// CFNetwork calls `startLoading` for every custom-protocol request on ONE
/// thread (`com.apple.CFNetwork.CustomProtocols`). A stub that answers inside
/// `startLoading`, as `InterceptProtocol` does, and sleeps there to simulate
/// latency makes each request wait for the one before it: two POSTs can never
/// be in flight at once, and "at most one in flight" holds whatever the sink
/// does. This stub records the request
/// and returns at once; the response goes back later, on that thread's run
/// loop, where `URLProtocolClient` calls have to be made.
private final class RelayStub: URLProtocol, @unchecked Sendable {

    /// Called with each request and its body. Call `respond` with a status
    /// code, now or later, from any thread.
    nonisolated(unsafe) static var handler:
        ((URLRequest, Data?, _ respond: @escaping @Sendable (Int) -> Void) -> Void)?

    /// Touched only on the loader thread.
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let runLoop = CFRunLoopGetCurrent()
        let mode = CFRunLoopCopyCurrentMode(runLoop).map { $0.rawValue as CFString }
            ?? CFRunLoopMode.defaultMode.rawValue
        handler(request, Self.body(of: request)) { [self] status in
            CFRunLoopPerformBlock(runLoop, mode) { self.finish(status) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    override func stopLoading() { stopped = true }

    private func finish(_ status: Int) {
        guard !stopped else { return }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a protocol the body as `httpBodyStream`, not `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            collected.append(buffer, count: n)
        }
        return collected
    }
}
