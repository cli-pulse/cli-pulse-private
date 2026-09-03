import XCTest
@testable import CLIPulseCore

/// Remote-control M0 — the phone client against the REAL agent router,
/// over an in-memory channel pair. No sockets; the whole request/reply
/// and event path is exercised.
final class LANSessionControlClientTests: XCTestCase {

    private func loopback(
        backend: FakeStreamingBackend = FakeStreamingBackend(),
        heartbeat: TimeInterval = 0.05,
        silence: TimeInterval = 10
    ) -> (client: LANSessionControlClient, backend: FakeStreamingBackend, agentRun: Task<LANLinkAgentSession.EndReason, Never>) {
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let agent = LANLinkAgentSession(
            channel: macEnd, backend: backend,
            identity: LANAgentIdentity(deviceID: "mac-1", displayName: "Studio", cloudDeviceID: "cloud-9"),
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
        XCTAssertFalse(h.capabilities.sendInput, "M0 is read-only")
        XCTAssertTrue(h.capabilities.subscribeEvents)
        XCTAssertFalse(h.capabilities.approvals)
        XCTAssertEqual(h.implementation, "swift-bundled")
        let info = try XCTUnwrap(client.helloInfo)
        XCTAssertEqual(info.deviceID, "mac-1")
        XCTAssertEqual(info.displayName, "Studio")
        XCTAssertEqual(info.cloudDeviceID, "cloud-9")
        XCTAssertTrue(info.helperReachable)
        XCTAssertTrue(info.readOnly)
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

    func testControlMethodsThrowNotImplementedWithoutTouchingTheWire() async throws {
        let (client, _, run) = loopback()
        do { _ = try await client.startManagedSession(provider: "claude", clientLabel: nil, cwdBasename: nil, cwdHmac: nil); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notImplemented) }
        do { try await client.stopSession(sessionId: "s1"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notImplemented) }
        do { try await client.sendInput(sessionId: "s1", payload: "x"); XCTFail() }
        catch { XCTAssertEqual(error as? SessionControlError, .notImplemented) }
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

    func testLocalControlOffOnTheMacSurfacesAsTypedErrorOnThePhone() async throws {
        let (client, backend, run) = loopback(heartbeat: 0.03)
        let stream = client.subscribeEvents(sessionId: "s1")
        var it = stream.makeAsyncIterator()
        _ = try await it.next()   // subscribed

        backend.lock.lock(); backend.localControl = false; backend.lock.unlock()

        do {
            while let _ = try await it.next() {}
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
