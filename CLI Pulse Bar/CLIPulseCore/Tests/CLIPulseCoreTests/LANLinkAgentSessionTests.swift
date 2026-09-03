import XCTest
@testable import CLIPulseCore

/// Remote-control M0 — the per-connection router, driven end to end over
/// an in-memory channel with a scripted backend. These are the tests
/// that say what a phone can and cannot get out of a Mac.
final class LANLinkAgentSessionTests: XCTestCase {

    // MARK: - Test phone

    /// Collects every frame the agent sends and lets a test send requests.
    final class Phone: @unchecked Sendable {
        let channel: InMemoryLANLinkChannel
        private let lock = NSLock()
        private var frames: [LANLinkFrame] = []
        private var waiters: [(String, CheckedContinuation<LANLinkFrame, Never>)] = []
        private var eventWaiters: [CheckedContinuation<LANLinkFrame, Never>] = []
        private var pumpTask: Task<Void, Never>?
        private(set) var inboundEnded = false

        init(channel: InMemoryLANLinkChannel) {
            self.channel = channel
            pumpTask = Task { [weak self] in
                guard let self else { return }
                do {
                    for try await body in channel.inbound {
                        guard let f = try? LANLinkFrame.decode(body) else { continue }
                        self.record(f)
                    }
                } catch {}
                self.lock.lock(); self.inboundEnded = true; self.lock.unlock()
            }
        }

        /// A frame goes to exactly one place: a waiter if one is parked,
        /// else the buffer. Doing both delivered every event twice and
        /// produced a phantom "seq not monotonic" failure against a
        /// router that was, in fact, monotonic.
        private func record(_ f: LANLinkFrame) {
            lock.lock()
            if case let .reply(id, _, _, _) = f, let i = waiters.firstIndex(where: { $0.0 == id }) {
                let w = waiters.remove(at: i); lock.unlock(); w.1.resume(returning: f); return
            }
            if case .event = f, !eventWaiters.isEmpty {
                let w = eventWaiters.removeFirst(); lock.unlock(); w.resume(returning: f); return
            }
            frames.append(f)
            lock.unlock()
        }

        func request(_ m: LANLinkProtocol.Method, _ p: [String: AnySendableJSON] = [:]) async throws -> LANLinkFrame {
            try await request(raw: m.rawValue, p)
        }

        func request(raw method: String, _ p: [String: AnySendableJSON] = [:]) async throws -> LANLinkFrame {
            let id = UUID().uuidString
            // Already-received replies are impossible here since id is fresh.
            async let reply: LANLinkFrame = withCheckedContinuation { k in
                lock.lock(); waiters.append((id, k)); lock.unlock()
            }
            try await channel.send(try LANLinkFrame.request(id: id, method: method, params: p).encode())
            return await reply
        }

        func nextEvent() async -> LANLinkFrame {
            lock.lock()
            if let i = frames.firstIndex(where: { if case .event = $0 { return true }; return false }) {
                let f = frames.remove(at: i); lock.unlock(); return f
            }
            lock.unlock()
            return await withCheckedContinuation { k in
                lock.lock(); eventWaiters.append(k); lock.unlock()
            }
        }

        func heartbeat() async throws {
            try await channel.send(try LANLinkFrame.heartbeat(ts: Date().timeIntervalSince1970).encode())
        }

        var allFrames: [LANLinkFrame] { lock.lock(); defer { lock.unlock() }; return frames }
        var ended: Bool { lock.lock(); defer { lock.unlock() }; return inboundEnded }

        /// The agent's `run()` returns after it calls `channel.close()`,
        /// but this end observes the close on its own pump task. Asserting
        /// `ended` synchronously raced under full-suite load; wait for it.
        func waitEnded(timeout: TimeInterval = 2) async -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !ended, Date() < deadline {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return ended
        }
    }

    private func makeSession(
        backend: FakeStreamingBackend = FakeStreamingBackend(),
        heartbeat: TimeInterval = 0.05,
        silence: TimeInterval = 10,
        idleFlush: TimeInterval = 0.05
    ) -> (session: LANLinkAgentSession, phone: Phone, backend: FakeStreamingBackend, run: Task<LANLinkAgentSession.EndReason, Never>) {
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let session = LANLinkAgentSession(
            channel: macEnd, backend: backend,
            identity: LANAgentIdentity(deviceID: "mac-1", displayName: "Test Mac", cloudDeviceID: "cloud-9"),
            heartbeatInterval: heartbeat, silenceTimeout: silence, redactionIdleFlush: idleFlush)
        let phone = Phone(channel: phoneEnd)
        let run = Task { await session.run() }
        return (session, phone, backend, run)
    }

    private func unwrapOK(_ f: LANLinkFrame, _ line: UInt = #line) throws -> [String: AnySendableJSON] {
        guard case let .reply(_, ok, r, e) = f else { XCTFail("not a reply: \(f)", line: line); throw XCTSkip() }
        XCTAssertTrue(ok, "error reply: \(e?.code ?? "?") \(e?.message ?? "")", line: line)
        return r
    }

    private func unwrapError(_ f: LANLinkFrame, _ line: UInt = #line) throws -> LANLinkWireError {
        guard case let .reply(_, ok, _, e) = f, !ok, let e else { XCTFail("expected error reply: \(f)", line: line); throw XCTSkip() }
        return e
    }

    // MARK: - hello

    func testHelloReportsIdentityCapabilitiesAndHelperState() async throws {
        let (session, phone, _, run) = makeSession()
        let r = try unwrapOK(try await phone.request(.hello))
        XCTAssertEqual(r["did"]?.stringValue, "mac-1")
        XCTAssertEqual(r["name"]?.stringValue, "Test Mac")
        XCTAssertEqual(r["cloud_device_id"]?.stringValue, "cloud-9")
        XCTAssertEqual(r["capabilities"]?.objectValue?["read_only"]?.boolValue, true)
        XCTAssertEqual(r["helper"]?.objectValue?["reachable"]?.boolValue, true)
        XCTAssertEqual(r["helper"]?.objectValue?["implementation"]?.stringValue, "swift-bundled")
        await session.close(); _ = await run.value
    }

    func testHelloSucceedsWhenHelperIsDownAndReportsIt() async throws {
        let b = FakeStreamingBackend(); b.helperReachable = false
        let (session, phone, _, run) = makeSession(backend: b)
        let r = try unwrapOK(try await phone.request(.hello))
        XCTAssertEqual(r["helper"]?.objectValue?["reachable"]?.boolValue, false)
        // But a read that NEEDS the helper is a typed error.
        let e = try unwrapError(try await phone.request(.sessionsList))
        XCTAssertEqual(e.code, "helper_not_running")
        XCTAssertEqual(e.asSessionControlError, .helperNotRunning)
        await session.close(); _ = await run.value
    }

    // MARK: - reads

    func testSessionsListEncodesRows() async throws {
        let (session, phone, _, run) = makeSession()
        let r = try unwrapOK(try await phone.request(.sessionsList))
        let rows = try XCTUnwrap(r["sessions"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].objectValue?["id"]?.stringValue, "s1")
        XCTAssertEqual(rows[0].objectValue?["provider"]?.stringValue, "claude")
        XCTAssertEqual(rows[0].objectValue?["client_label"]?.stringValue, "proj")
        await session.close(); _ = await run.value
    }

    func testTailIsRedactedAtEgressEvenIfHelperForgot() async throws {
        let b = FakeStreamingBackend()
        b.tail = Data("token: sk-ant-api03-AAAABBBBCCCCDDDDEEEE\n".utf8)
        let (session, phone, _, run) = makeSession(backend: b)
        let r = try unwrapOK(try await phone.request(.sessionTail, ["session_id": .string("s1")]))
        let bytes = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(r["bytes_b64"]?.stringValue)))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("sk-ant-api03"), text)
        XCTAssertTrue(text.contains(LANEgressRedactor.redactionMarker))
        await session.close(); _ = await run.value
    }

    func testTailForUnknownSessionIsTypedError() async throws {
        let (session, phone, _, run) = makeSession()
        let e = try unwrapError(try await phone.request(.sessionTail, ["session_id": .string("nope")]))
        XCTAssertEqual(e.asSessionControlError, .sessionNotFound)
        let e2 = try unwrapError(try await phone.request(.sessionTail))
        XCTAssertEqual(e2.code, "bad_request")
        await session.close(); _ = await run.value
    }

    // MARK: - the M0 boundary

    func testEveryM1VerbIsRefusedWithNotImplemented() async throws {
        // THE M0 boundary. The backend's control methods XCTFail if
        // reached, so this proves refusal happens BEFORE the helper.
        let (session, phone, _, run) = makeSession()
        for m in LANLinkProtocol.Method.allCases where !m.isReadOnly {
            let e = try unwrapError(try await phone.request(m, ["session_id": .string("s1"), "payload": .string("rm -rf /")]))
            XCTAssertEqual(e.code, "not_implemented", m.rawValue)
        }
        await session.close(); _ = await run.value
    }

    func testUnknownMethodIsBadRequest() async throws {
        let (session, phone, _, run) = makeSession()
        let e = try unwrapError(try await phone.request(raw: "send_input"))   // helper spelling, not ours
        XCTAssertEqual(e.code, "bad_request")
        await session.close(); _ = await run.value
    }

    func testClientSendingAServerFrameEndsTheSession() async throws {
        let (_, phone, _, run) = makeSession()
        try await phone.channel.send(try LANLinkFrame.event(kind: "output", subscription: "x", seq: 1, data: [:]).encode())
        let reason = await run.value
        guard case .protocolViolation = reason else { return XCTFail("expected protocolViolation, got \(reason)") }
        let phoneEnded = await phone.waitEnded()
        XCTAssertTrue(phoneEnded)
    }

    // MARK: - subscriptions

    func testSubscriptionStreamsRedactedOutputWithMonotonicSeq() async throws {
        let (session, phone, backend, run) = makeSession()
        let r = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        let sub = try XCTUnwrap(r["sub"]?.stringValue)

        // A secret split across two PTY chunks, mid-token, no key context.
        backend.push(.outputDelta(sessionId: "s1", payload: "Loaded credential sk-ant-a", ts: 1))
        backend.push(.outputDelta(sessionId: "s1", payload: "pi03-AAAABBBBCCCCDDDDEEEEFFFF from disk\n", ts: 2))
        backend.push(.outputDelta(sessionId: "s1", payload: "all done\n", ts: 3))

        var text = ""
        var lastSeq: UInt64 = 0
        while !text.contains("all done") {
            let f = await phone.nextEvent()
            guard case let .event(kind, s, seq, d) = f else { continue }
            XCTAssertEqual(s, sub)
            XCTAssertGreaterThan(seq, lastSeq, "seq must be strictly monotonic"); lastSeq = seq
            if kind == "output", let b = d["bytes_b64"]?.stringValue, let data = Data(base64Encoded: b) {
                text += String(decoding: data, as: UTF8.self)
            }
        }
        XCTAssertFalse(text.contains("sk-ant-api03"), "secret crossed the LAN: \(text.debugDescription)")
        XCTAssertTrue(text.contains(LANEgressRedactor.redactionMarker))
        XCTAssertTrue(text.contains("all done"))
        await session.close(); _ = await run.value
    }

    func testPromptWithoutNewlineIsFlushedByIdleTimer() async throws {
        // "proceed? (y/n)" never ends in a newline. The line-hold
        // redactor would sit on it forever; the idle flush must not.
        let (session, phone, backend, run) = makeSession(idleFlush: 0.05)
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.push(.outputDelta(sessionId: "s1", payload: "Do you want to proceed? (y/n) ", ts: 1))
        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, d) = f, kind == "output",
              let b = d["bytes_b64"]?.stringValue, let data = Data(base64Encoded: b) else {
            return XCTFail("expected an output event, got \(f)")
        }
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "Do you want to proceed? (y/n) ")
        await session.close(); _ = await run.value
    }

    func testApprovalEventsAreNotForwardedInM0() async throws {
        let (session, phone, backend, run) = makeSession()
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.push(.approvalRequested(approval: PendingApproval(
            approvalId: "a1", sessionId: "s1", type: "PermissionRequest", title: "t", summary: "s",
            toolMetadata: [:], status: "pending", createdAt: Date(), expiresAt: nil)))
        backend.push(.outputDelta(sessionId: "s1", payload: "marker\n", ts: 1))
        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, _) = f else { return XCTFail() }
        XCTAssertEqual(kind, "output", "an approval event leaked to a read-only client")
        await session.close(); _ = await run.value
    }

    func testSubscriptionLimitIsEnforced() async throws {
        let (session, phone, _, run) = makeSession()
        for _ in 0..<LANLinkProtocol.maxSubscriptionsPerConnection {
            _ = try unwrapOK(try await phone.request(.sessionSubscribe))
        }
        let e = try unwrapError(try await phone.request(.sessionSubscribe))
        XCTAssertEqual(e.code, "subscription_limit")
        await session.close(); _ = await run.value
    }

    func testUnsubscribeStopsEventsAndUnknownSubIsError() async throws {
        let (session, phone, backend, run) = makeSession()
        let r = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        let sub = try XCTUnwrap(r["sub"]?.stringValue)
        _ = try unwrapOK(try await phone.request(.sessionUnsubscribe, ["sub": .string(sub)]))
        let e = try unwrapError(try await phone.request(.sessionUnsubscribe, ["sub": .string(sub)]))
        XCTAssertEqual(e.code, "subscription_not_found")
        backend.push(.outputDelta(sessionId: "s1", payload: "after\n", ts: 1))
        try await Task.sleep(nanoseconds: 100_000_000)
        let outputs = phone.allFrames.filter { if case .event(let k, _, _, _) = $0 { return k == "output" }; return false }
        XCTAssertTrue(outputs.isEmpty, "events after unsubscribe: \(outputs)")
        await session.close(); _ = await run.value
    }

    func testHelperStreamEndingNotifiesThePhone() async throws {
        let (session, phone, backend, run) = makeSession()
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.finishStreams()
        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, d) = f else { return XCTFail() }
        XCTAssertEqual(kind, "subscription_ended")
        XCTAssertEqual(d["reason"]?.stringValue, "session_gone")
        await session.close(); _ = await run.value
    }

    // MARK: - the revocation lever

    func testTurningLocalControlOffEndsStreamsAndClosesTheConnection() async throws {
        // The user's only way to revoke. The helper checks its gate once
        // per subscription; the agent must keep checking.
        let (_, phone, backend, run) = makeSession(heartbeat: 0.03)
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))

        backend.lock.lock(); backend.localControl = false; backend.lock.unlock()

        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, d) = f else { return XCTFail("expected event, got \(f)") }
        XCTAssertEqual(kind, "subscription_ended")
        XCTAssertEqual(d["reason"]?.stringValue, "local_control_disabled")
        let reason = await run.value
        XCTAssertEqual(reason, .localControlDisabled)
        let phoneEnded = await phone.waitEnded()
        XCTAssertTrue(phoneEnded, "connection must be closed, not just the stream")
    }

    func testBackendThatCannotAnswerTheGateIsTreatedAsOff() async throws {
        // Fail closed: if we cannot ask, the answer is no.
        final class Flaky: FakeStreamingBackend {
            override func isLocalControlEnabled() async throws -> Bool { throw SessionControlError.timeout }
        }
        let (_, _, _, run) = makeSession(backend: Flaky(), heartbeat: 0.03)
        let reason = await run.value
        XCTAssertEqual(reason, .localControlDisabled)
    }

    // MARK: - liveness

    func testAgentSendsHeartbeats() async throws {
        let (session, phone, _, run) = makeSession(heartbeat: 0.03)
        try await Task.sleep(nanoseconds: 150_000_000)
        let hbs = phone.allFrames.filter { if case .heartbeat = $0 { return true }; return false }
        XCTAssertGreaterThanOrEqual(hbs.count, 2)
        await session.close(); _ = await run.value
    }

    func testSilentPhoneIsDisconnected() async throws {
        let (_, phone, _, run) = makeSession(heartbeat: 0.03, silence: 0.1)
        // Send nothing.
        let reason = await run.value
        XCTAssertEqual(reason, .peerSilent)
        let phoneEnded = await phone.waitEnded()
        XCTAssertTrue(phoneEnded)
    }

    func testHeartbeatsKeepAChattyPhoneAlive() async throws {
        let (session, phone, _, run) = makeSession(heartbeat: 0.03, silence: 0.1)
        for _ in 0..<6 {
            try await phone.heartbeat()
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        XCTAssertFalse(phone.ended, "heartbeating phone was disconnected")
        await session.close(); _ = await run.value
    }
}
