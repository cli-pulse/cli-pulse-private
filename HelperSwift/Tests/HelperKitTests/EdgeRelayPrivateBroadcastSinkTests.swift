import XCTest
@testable import HelperKit
import Foundation

/// Pins the HTTP wire shape and the delivery behaviour of
/// `EdgeRelayPrivateBroadcastSink`. The first cut of that type had NO test
/// past its `guard channel.hasPrefix("pterm:")` line — every property below
/// was unverified, including two that turned out to be wrong.
///
/// Uses the shared `InterceptProtocol` from `SupabaseRPCCallerTests.swift`.
final class EdgeRelayPrivateBroadcastSinkTests: XCTestCase {

    /// Records every intercepted request, in order, and tracks how many were
    /// in flight simultaneously.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _bodies: [[String: Any]] = []
        private var _urls: [String] = []
        private var _headers: [[String: String]] = []
        private var inFlight = 0
        private(set) var maxInFlight = 0
        var status = 200
        var delayMs: UInt32 = 0

        var bodies: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return _bodies }
        var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
        var headers: [[String: String]] { lock.lock(); defer { lock.unlock() }; return _headers }

        /// All data_b64 values across all requests, flattened in send order.
        var flatChunks: [String] {
            bodies.flatMap { ($0["chunks"] as? [[String: Any]] ?? []).compactMap { $0["data_b64"] as? String } }
        }

        func install() {
            InterceptProtocol.responder = { [self] req in
                lock.lock()
                inFlight += 1
                maxInFlight = max(maxInFlight, inFlight)
                _urls.append(req.url?.absoluteString ?? "")
                _headers.append(req.allHTTPHeaderFields ?? [:])
                let body = InterceptProtocol.lastBodyData
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                _bodies.append(body ?? [:])
                let d = delayMs, st = status
                lock.unlock()

                if d > 0 { usleep(d * 1000) }

                lock.lock(); inFlight -= 1; lock.unlock()
                let resp = HTTPURLResponse(
                    url: req.url!, statusCode: st, httpVersion: nil, headerFields: nil)!
                return (resp, Data("{}".utf8))
            }
        }
    }

    private var rec: Recorder!

    override func setUp() {
        super.setUp()
        InterceptProtocol.reset()
        URLProtocol.registerClass(InterceptProtocol.self)
        rec = Recorder()
        rec.install()
    }

    override func tearDown() {
        URLProtocol.unregisterClass(InterceptProtocol.self)
        InterceptProtocol.reset()
        rec = nil
        super.tearDown()
    }

    private static let cloud = HelperConfigStore.CloudConfig(
        deviceId: "11111111-2222-3333-4444-555555555555",
        helperSecret: "stub-secret",
        supabaseURL: "https://example.supabase.co",
        supabaseAnonKey: "anon-key"
    )

    private func makeSink(
        coalesce: Duration = .milliseconds(1),
        denialBackoff: Duration = .milliseconds(80),
        cloud: HelperConfigStore.CloudConfig? = nil
    ) -> EdgeRelayPrivateBroadcastSink {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterceptProtocol.self]
        let c = cloud ?? Self.cloud
        return EdgeRelayPrivateBroadcastSink(
            configProvider: { c },
            coalesceWindow: coalesce,
            denialBackoff: denialBackoff,
            session: URLSession(configuration: cfg))
    }

    private func publish(_ sink: EdgeRelayPrivateBroadcastSink, _ sid: String, _ text: String) async {
        try? await sink.publish(
            sessionId: sid, channel: "pterm:\(sid)", event: "stdout",
            redactedBytes: Data(text.utf8))
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
        rec.delayMs = 40
        let sink = makeSink(coalesce: .milliseconds(1))
        for i in 1...12 {
            await publish(sink, "sid-1", "c\(i)")
            try? await Task.sleep(for: .milliseconds(5))
        }
        // Drain whatever is left.
        for _ in 0..<12 {
            await sink.flushNow()
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(rec.maxInFlight, 1,
                       "overlapping POSTs for one session can reorder terminal output")
        let expected = (1...12).map { Data("c\($0)".utf8).base64EncodedString() }
        XCTAssertEqual(rec.flatChunks, expected, "chunks must arrive in submit order")
    }

    func test_noChunkIsStrandedWhenItArrivesDuringAnInFlightPost() async {
        rec.delayMs = 30
        let sink = makeSink(coalesce: .milliseconds(1))
        await publish(sink, "sid-1", "first")
        // Arrives while the first POST is in flight.
        try? await Task.sleep(for: .milliseconds(5))
        await publish(sink, "sid-1", "second")
        for _ in 0..<10 {
            await sink.flushNow()
            try? await Task.sleep(for: .milliseconds(15))
        }
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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterceptProtocol.self]
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { Self.cloud },
            coalesceWindow: .milliseconds(1),
            maxBatchCount: 1,
            session: URLSession(configuration: cfg))
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
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterceptProtocol.self]
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { Self.cloud },
            coalesceWindow: .seconds(60),   // never fires during the test
            maxPendingPerSession: 8,
            session: URLSession(configuration: cfg))
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
        rec.delayMs = 120
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [InterceptProtocol.self]
        let sink = EdgeRelayPrivateBroadcastSink(
            configProvider: { Self.cloud },
            coalesceWindow: .milliseconds(1),
            maxBatchCount: 1,            // one group per chunk => a visible tail
            session: URLSession(configuration: cfg))
        for i in 1...5 { await publish(sink, "sid-1", "c\(i)") }
        // Let the first POST get in flight, then revoke.
        try? await Task.sleep(for: .milliseconds(60))
        await sink.purge(sessionId: "sid-1")
        try? await Task.sleep(for: .milliseconds(600))
        XCTAssertLessThanOrEqual(
            rec.urls.count, 2,
            "a revoke must abandon the rest of the tail, not deliver it — got \(rec.urls.count) POSTs")
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
