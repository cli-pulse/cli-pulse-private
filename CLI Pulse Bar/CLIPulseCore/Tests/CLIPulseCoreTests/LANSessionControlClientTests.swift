import XCTest
@testable import CLIPulseCore

/// Remote-control M0 — the phone client against the REAL agent router,
/// over an in-memory channel pair. No sockets; the whole request/reply
/// and event path is exercised.
final class LANSessionControlClientTests: XCTestCase {

    private func loopback(
        backend: FakeStreamingBackend = FakeStreamingBackend(),
        peer: LANAgentPeer? = LANAgentPeer(id: "phone-1", displayName: "Probe", controlAllowed: true),
        heartbeat: TimeInterval = 0.05,
        silence: TimeInterval = 10
    ) -> (client: LANSessionControlClient, backend: FakeStreamingBackend, agentRun: Task<LANLinkAgentSession.EndReason, Never>) {
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let agent = LANLinkAgentSession(
            channel: macEnd, backend: backend,
            identity: LANAgentIdentity(deviceID: "mac-1", displayName: "Studio", cloudDeviceID: "cloud-9", home: "/Users/s"),
            peer: peer,
            heartbeatInterval: heartbeat, silenceTimeout: silence, redactionIdleFlush: 0.05)
        let run = Task { await agent.run() }
        let client = LANSessionControlClient(channel: phoneEnd, heartbeatInterval: heartbeat, silenceTimeout: silence)
        return (client, backend, run)
    }

    func testHelloMapsToSessionControlHelloAndKeepsLANDetails() async throws {
        let (client, _, run) = loopback()
        let h = try await client.hello()
        XCTAssertEqual(h.protocolVersion, 1)
        XCTAssertTrue(h.supportedMethods.contains("sessions.list"))
        XCTAssertTrue(h.supportedMethods.contains("session.input"))
        XCTAssertTrue(h.capabilities.sendInput)
        XCTAssertTrue(h.capabilities.subscribeEvents)
        XCTAssertTrue(h.capabilities.approvals)
        XCTAssertEqual(h.implementation, "swift-bundled")
        XCTAssertEqual(h.providerAvailability, ["claude", "gemini"])
        XCTAssertEqual(h.claudeRemoteControl?["policy"], "allowed")
        let info = try XCTUnwrap(client.helloInfo)
        XCTAssertEqual(info.deviceID, "mac-1")
        XCTAssertEqual(info.displayName, "Studio")
        XCTAssertEqual(info.cloudDeviceID, "cloud-9")
        XCTAssertTrue(info.helperReachable)
        XCTAssertFalse(info.readOnly)
        XCTAssertTrue(info.controlAllowed)
        XCTAssertEqual(info.home, "/Users/s")
        client.close(); _ = await run.value
    }

    func testHelloFromAReadOnlyLinkSaysSo() async throws {
        let (client, _, run) = loopback(peer: nil)
        let h = try await client.hello()
        XCTAssertFalse(h.capabilities.sendInput)
        XCTAssertFalse(h.capabilities.approvals)
        XCTAssertFalse(h.supportedMethods.contains("session.input"))
        XCTAssertTrue(try XCTUnwrap(client.helloInfo).readOnly)
        client.close(); _ = await run.value
    }

    func testControlMethodsRoundTripToTheBackend() async throws {
        let (client, backend, run) = loopback()
        try await client.sendInputRaw(sessionId: "s1", bytes: Data("\u{03}".utf8))
        try await client.resize(sessionId: "s1", cols: 100, rows: 30)
        let started = try await client.startManagedSession(provider: "gemini", clientLabel: "phone", cwd: "/Users/s/x", claudeRemoteControl: false)
        XCTAssertEqual(started.sessionId, "new-1")
        try await client.stopSession(sessionId: "s1")
        backend.pendingApprovals = [.fixture(id: "a1")]
        let pending = try await client.getPendingApprovals(sessionId: "s1")
        XCTAssertEqual(pending.map(\.approvalId), ["a1"])
        let first = try XCTUnwrap(pending.first, "the approval was dropped on decode")
        XCTAssertEqual(first.title, "Bash")
        XCTAssertEqual(first.expiresAt, Date(timeIntervalSince1970: 1_700_000_060))
        try await client.approveAction(sessionId: "s1", approvalId: "a1", decision: .approve, comment: nil)
        XCTAssertEqual(backend.recordedControlCalls, [
            "input s1 \u{03}", "resize s1 100x30", "start gemini label=phone cwd=/Users/s/x rc=false", "stop s1", "decide s1 a1 approve",
        ])
        client.close(); _ = await run.value
    }

    func testControlErrorsAreTypedOnThePhone() async throws {
        let (client, backend, run) = loopback()
        backend.approveError = SessionControlError.approvalAlreadyResolved
        do { try await client.approveAction(sessionId: "s1", approvalId: "a1", decision: .approve, comment: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .approvalAlreadyResolved) }
        do { try await client.sendInputRaw(sessionId: "nope", bytes: Data("x".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .sessionNotFound) }
        do { try await client.resize(sessionId: "s1", cols: 0, rows: 0); XCTFail() }
        catch { guard case .invalidResponse = (error as? SessionControlError) else { return XCTFail("\(error)") } }
        client.close(); _ = await run.value
    }

    func testAReadOnlyLinkRefusesControlWithATypedErrorBeforeTheWire() async throws {
        let (client, backend, run) = loopback(peer: nil)
        _ = try await client.hello()
        do { try await client.sendInputRaw(sessionId: "s1", bytes: Data("x".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notControllable) }
        XCTAssertEqual(backend.recordedControlCalls, [])
        client.close(); _ = await run.value
    }

    func testAnM0MacRefusingAnM1VerbSurfacesAsNotImplemented() async throws {
        // Hand-crafted M0 replies: control verbs answer `not_implemented`,
        // an unknown verb (`approvals.list`) answers `bad_request`. Both
        // mean "this Mac cannot do M1" on the phone.
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let client = LANSessionControlClient(channel: phoneEnd, heartbeatInterval: 10, silenceTimeout: 10)
        let answer = Task {
            var it = macEnd.inbound.makeAsyncIterator()
            for _ in 0..<2 {
                guard let body = try await it.next(), case let .request(id, m, _) = try LANLinkFrame.decode(body) else { return }
                let code = m == "approvals.list" ? "bad_request" : "not_implemented"
                try await macEnd.send(try LANLinkFrame.reply(id: id, ok: false, result: [:],
                    error: LANLinkWireError(code: code, message: "unknown method: \(m)")).encode())
            }
        }
        do { try await client.sendInputRaw(sessionId: "s1", bytes: Data("x".utf8)); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notImplemented) }
        do { _ = try await client.getPendingApprovals(sessionId: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notImplemented) }
        _ = try? await answer.value
        client.close()
    }

    func testApprovalAndRemoteControlEventsDecodeOnThePhone() async throws {
        let (client, backend, run) = loopback()
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()
        _ = try await it.next()
        backend.push(.approvalRequested(approval: .fixture(id: "a9", summary: "plain")))
        backend.push(.approvalResolved(sessionId: "s1", approvalId: "a9", decision: "approved", status: "approved"))
        backend.push(.sessionRemoteControl(sessionId: "s1", status: "ready", url: "https://claude.ai/code/abc123DEF", reason: nil))
        var got: [LocalSessionEvent] = []
        while got.count < 3, let e = try await it.next() { got.append(e) }
        guard case let .approvalRequested(a) = got[0] else { return XCTFail("\(got[0])") }
        XCTAssertEqual(a.approvalId, "a9"); XCTAssertEqual(a.summary, "plain"); XCTAssertEqual(a.title, "Bash")
        XCTAssertEqual(got[1], .approvalResolved(sessionId: "s1", approvalId: "a9", decision: "approved", status: "approved"))
        XCTAssertEqual(got[2], .sessionRemoteControl(sessionId: "s1", status: "ready", url: "https://claude.ai/code/abc123DEF", reason: nil))
        client.close(); _ = await run.value
    }

    func testCancellingASubscriptionBeforeTheReplyStillUnsubscribes() async throws {
        // The screen was dismissed while `session.subscribe` was in
        // flight. The agent-side subscription must still be released, or
        // four such dismissals hit the per-connection cap for good.
        let (client, _, run) = loopback()
        for _ in 0..<(LANLinkProtocol.maxSubscriptionsPerConnection + 2) {
            let stream = client.subscribeEvents(sessionId: "s1")
            let consumer = Task { for try await _ in stream {} }
            consumer.cancel()
            _ = try? await consumer.value
            // The release happens when the in-flight reply lands; give it
            // that moment. The property is "eventually released", not
            // "released before the next subscribe is on the wire".
            try await Task.sleep(nanoseconds: 60_000_000)
        }
        // If any leaked, this one is over the cap and throws.
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()
        guard case .subscribed = try await it.next() else { return XCTFail("subscription cap was exhausted by cancelled subscribes") }
        client.close(); _ = await run.value
    }

    func testListSessionsRoundTrips() async throws {
        let (client, _, run) = loopback()
        let rows = try await client.listSessions()
        XCTAssertEqual(rows.map(\.id), ["s1"])
        XCTAssertEqual(rows[0].provider, "claude")
        XCTAssertEqual(rows[0].clientLabel, "proj")
        XCTAssertEqual(rows[0].source, .managed)
        client.close(); _ = await run.value
    }

    func testTailRoundTripsRedacted() async throws {
        let b = FakeStreamingBackend()
        b.tail = Data("api_key=sk-ant-api03-AAAABBBBCCCCDDDD\n".utf8)
        let (client, _, run) = loopback(backend: b)
        let data = try await client.getTailSnapshot(sessionId: "s1", maxBytes: 4096)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-ant-api03"))
        XCTAssertTrue(text.contains(LANEgressRedactor.redactionMarker))
        client.close(); _ = await run.value
    }

    func testSubscriptionDeliversTypedEventsInOrder() async throws {
        let (client, backend, run) = loopback()
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()

        guard case .subscribed = try await it.next() else { return XCTFail("first event must be .subscribed") }

        backend.push(.outputDelta(sessionId: "s1", payload: "hello\n", ts: 1))
        backend.push(.sessionStatus(sessionId: "s1", status: "waiting"))
        backend.push(.sessionStopped(sessionId: "s1", exitCode: 0))

        var got: [LocalSessionEvent] = []
        while got.count < 3, let e = try await it.next() { got.append(e) }

        XCTAssertEqual(got[0], .outputRaw(sessionId: "s1", payload: "hello\n", ts: 0))
        XCTAssertEqual(got[1], .sessionStatus(sessionId: "s1", status: "waiting"))
        XCTAssertEqual(got[2], .sessionStopped(sessionId: "s1", exitCode: 0))
        client.close(); _ = await run.value
    }

    /// PROBE (2026-09-06): the real app holds TWO subscriptions on ONE
    /// client — the Mac screen's all-sessions one, and the terminal
    /// screen's session-scoped one. No test has ever opened both. On
    /// hardware the terminal's stream ends immediately while the Mac
    /// screen's keeps delivering approvals.
    func testTwoConcurrentSubscriptionsOnOneClientBothStayAlive() async throws {
        let (client, backend, run) = loopback()
        let all = client.subscribeEvents(sessionId: nil)          // Mac screen
        var allIt = all.makeAsyncIterator()
        guard case .subscribed = try await allIt.next() else { return XCTFail("all: no ack") }

        let one = client.subscribeEvents(sessionId: "s1")         // terminal screen
        var oneIt = one.makeAsyncIterator()
        guard case .subscribed = try await oneIt.next() else { return XCTFail("one: no ack") }

        backend.push(.outputDelta(sessionId: "s1", payload: "after both\n", ts: 1))

        let fromOne = try await oneIt.next()
        XCTAssertEqual(fromOne, .outputRaw(sessionId: "s1", payload: "after both\n", ts: 0),
                       "the session-scoped subscription died once a second one existed")
        let fromAll = try await allIt.next()
        XCTAssertEqual(fromAll, .outputRaw(sessionId: "s1", payload: "after both\n", ts: 0),
                       "the all-sessions subscription died once a second one existed")
        client.close(); _ = await run.value
    }

    func testLocalControlOffOnTheMacSurfacesAsTypedErrorOnThePhone() async throws {
        let (client, backend, run) = loopback(heartbeat: 0.03)
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()
        _ = try await it.next()   // subscribed

        backend.lock.lock(); backend.localControl = false; backend.lock.unlock()

        do {
            while try await it.next() != nil {}
            XCTFail("stream ended cleanly; expected localControlOff")
        } catch {
            XCTAssertEqual(error as? SessionControlError, .localControlOff)
        }
        _ = await run.value
    }

    func testHelperStreamEndingFinishesThePhoneStreamCleanly() async throws {
        let (client, backend, run) = loopback()
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()
        _ = try await it.next()
        backend.finishStreams()
        let next = try await it.next()
        XCTAssertNil(next, "session_gone must finish the stream, not throw")
        client.close(); _ = await run.value
    }

    func testAgentClosingIsObservedByThePhone() async throws {
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let agent = LANLinkAgentSession(
            channel: macEnd, backend: FakeStreamingBackend(),
            identity: LANAgentIdentity(deviceID: "m", displayName: "M", cloudDeviceID: nil),
            heartbeatInterval: 10, silenceTimeout: 10)
        let run = Task { await agent.run() }
        let client = LANSessionControlClient(channel: phoneEnd, heartbeatInterval: 10, silenceTimeout: 10)
        let disconnected = LockedBox<Bool>(false)
        client.onDisconnect = { _ in disconnected.set(true) }
        _ = try await client.hello()

        await agent.close()
        _ = await run.value
        // Give the pump a moment to observe the close.
        for _ in 0..<50 where !disconnected.get() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(disconnected.get())
        XCTAssertTrue(client.isClosed)
        do { _ = try await client.listSessions(); XCTFail("request after close must throw") }
        catch { XCTAssertEqual(error as? SessionControlError, .disconnected) }
    }

    func testSilentAgentTimesOutThePhone() async throws {
        // The Mac dropped off Wi-Fi: no frames of any kind arrive.
        let (_, phoneEnd) = InMemoryLANLinkChannel.pair()   // no agent on the other end
        let client = LANSessionControlClient(channel: phoneEnd, heartbeatInterval: 0.03, silenceTimeout: 0.1)
        let disconnected = LockedBox<Error?>(nil)
        let fired = LockedBox<Bool>(false)
        client.onDisconnect = { e in disconnected.set(e); fired.set(true) }
        for _ in 0..<100 where !fired.get() { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(fired.get(), "phone did not notice the silent Mac")
        XCTAssertEqual(disconnected.get() as? SessionControlError, .timeout)
    }

    func testSeqGapIsSurfacedNotHidden() async throws {
        // Hand-craft frames from a fake agent to skip a seq number.
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let client = LANSessionControlClient(channel: phoneEnd, heartbeatInterval: 10, silenceTimeout: 10)
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()

        // Answer the subscribe request by hand.
        var macIt = macEnd.inbound.makeAsyncIterator()
        let reqBody = try await macIt.next()!
        guard case let .request(id, m, _) = try LANLinkFrame.decode(reqBody), m == "session.subscribe" else { return XCTFail() }
        try await macEnd.send(try LANLinkFrame.reply(id: id, ok: true, result: ["sub": .string("S")], error: nil).encode())
        _ = try await it.next()   // subscribed

        try await macEnd.send(try LANLinkFrame.event(kind: "output", subscription: "S", seq: 1, data: ["session_id": .string("s1"), "bytes_b64": .string(Data("a".utf8).base64EncodedString())]).encode())
        try await macEnd.send(try LANLinkFrame.event(kind: "output", subscription: "S", seq: 3, data: ["session_id": .string("s1"), "bytes_b64": .string(Data("c".utf8).base64EncodedString())]).encode())

        let e1 = try await it.next()
        XCTAssertEqual(e1, .outputRaw(sessionId: "s1", payload: "a", ts: 0))
        let gap = try await it.next()
        guard case let .other(name, _)? = gap, name == "seq_gap" else { return XCTFail("expected seq_gap, got \(String(describing: gap))") }
        let e3 = try await it.next()
        XCTAssertEqual(e3, .outputRaw(sessionId: "s1", payload: "c", ts: 0))
        client.close()
    }
}
