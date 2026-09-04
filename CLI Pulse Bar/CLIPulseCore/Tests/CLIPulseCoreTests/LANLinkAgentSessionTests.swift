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

        /// Await the reply to a request sent by hand on the channel.
        func reply(for id: String) async -> LANLinkFrame {
            lock.lock()
            if let i = frames.firstIndex(where: { if case let .reply(rid, _, _, _) = $0 { return rid == id }; return false }) {
                let f = frames.remove(at: i); lock.unlock(); return f
            }
            lock.unlock()
            return await withCheckedContinuation { k in
                lock.lock(); waiters.append((id, k)); lock.unlock()
            }
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

    /// The default peer is attributed AND permitted — M1's happy path.
    /// Pass `peer: nil` for an unattributed connection (M0 phone, or a
    /// pairing-key connection), or a peer with `controlAllowed: false`.
    private func makeSession(
        backend: FakeStreamingBackend = FakeStreamingBackend(),
        peer: LANAgentPeer? = LANAgentPeer(id: "phone-1", displayName: "Probe", controlAllowed: true),
        heartbeat: TimeInterval = 0.05,
        silence: TimeInterval = 10,
        idleFlush: TimeInterval = 0.05
    ) -> (session: LANLinkAgentSession, phone: Phone, backend: FakeStreamingBackend, run: Task<LANLinkAgentSession.EndReason, Never>) {
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let session = LANLinkAgentSession(
            channel: macEnd, backend: backend,
            identity: LANAgentIdentity(deviceID: "mac-1", displayName: "Test Mac", cloudDeviceID: "cloud-9", home: "/Users/t"),
            peer: peer,
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

    private func errorCode(_ phone: Phone, _ m: LANLinkProtocol.Method, _ p: [String: AnySendableJSON] = [:]) async throws -> String {
        try unwrapError(try await phone.request(m, p)).code
    }

    // MARK: - hello

    func testHelloReportsIdentityCapabilitiesAndHelperState() async throws {
        let (session, phone, _, run) = makeSession()
        let r = try unwrapOK(try await phone.request(.hello))
        XCTAssertEqual(r["did"]?.stringValue, "mac-1")
        XCTAssertEqual(r["name"]?.stringValue, "Test Mac")
        XCTAssertEqual(r["cloud_device_id"]?.stringValue, "cloud-9")
        XCTAssertEqual(r["capabilities"]?.objectValue?["read_only"]?.boolValue, false)
        XCTAssertEqual(r["capabilities"]?.objectValue?["control"]?.boolValue, true)
        XCTAssertEqual(r["capabilities"]?.objectValue?["approvals"]?.boolValue, true)
        XCTAssertEqual(r["helper"]?.objectValue?["reachable"]?.boolValue, true)
        XCTAssertEqual(r["helper"]?.objectValue?["implementation"]?.stringValue, "swift-bundled")
        XCTAssertEqual(r["home"]?.stringValue, "/Users/t")
        XCTAssertEqual(r["peer"]?.objectValue?["id"]?.stringValue, "phone-1")
        XCTAssertEqual(r["peer"]?.objectValue?["control_allowed"]?.boolValue, true)
        XCTAssertEqual(Set(r["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                       Set(LANLinkProtocol.Method.allCases.map(\.rawValue)))
        XCTAssertEqual(r["helper"]?.objectValue?["provider_availability"]?.arrayValue?.compactMap(\.stringValue), ["claude", "gemini"])
        XCTAssertEqual(r["helper"]?.objectValue?["claude_remote_control"]?.objectValue?["policy"]?.stringValue, "allowed")
        await session.close(); _ = await run.value
    }

    func testHelloForAnUnpermittedOrUnattributedPeerIsReadOnly() async throws {
        for peer in [LANAgentPeer(id: "phone-2", displayName: "Old", controlAllowed: false), nil] {
            let (session, phone, _, run) = makeSession(peer: peer)
            let r = try unwrapOK(try await phone.request(.hello))
            XCTAssertEqual(r["capabilities"]?.objectValue?["read_only"]?.boolValue, true, "\(String(describing: peer))")
            XCTAssertEqual(r["capabilities"]?.objectValue?["control"]?.boolValue, false)
            XCTAssertEqual(Set(r["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []),
                           Set(LANLinkProtocol.Method.readOnly.map(\.rawValue)))
            if peer == nil { XCTAssertNil(r["peer"]) }
            await session.close(); _ = await run.value
        }
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

    // MARK: - the permission boundary

    func testEveryM1VerbIsRefusedForAnUnpermittedOrUnattributedPeer() async throws {
        // THE M1 boundary. Refusal must happen BEFORE the helper: the
        // backend records every control call, and the record stays empty.
        for peer in [LANAgentPeer(id: "phone-2", displayName: "Old", controlAllowed: false), nil] {
            let (session, phone, backend, run) = makeSession(peer: peer)
            for m in LANLinkProtocol.Method.m1 {
                let e = try unwrapError(try await phone.request(m, [
                    "session_id": .string("s1"), "bytes_b64": .string(Data("rm -rf /\n".utf8).base64EncodedString()),
                    "cols": .int(80), "rows": .int(24), "provider": .string("claude"),
                    "approval_id": .string("a1"), "decision": .string("approve"),
                ]))
                XCTAssertEqual(e.code, "control_not_allowed", "\(m.rawValue) for \(String(describing: peer))")
            }
            XCTAssertEqual(backend.recordedControlCalls, [], "the helper must never see a refused verb")
            await session.close(); _ = await run.value
        }
    }

    func testPermissionIsReCheckedPerRequestNotCachedAtHello() async throws {
        // The Mac user flips the per-phone toggle off mid-session: the
        // very next control frame is refused, no reconnect needed.
        let permitted = LockedBox<Bool>(true)
        let (macEnd, phoneEnd) = InMemoryLANLinkChannel.pair()
        let backend = FakeStreamingBackend()
        let session = LANLinkAgentSession(
            channel: macEnd, backend: backend,
            identity: LANAgentIdentity(deviceID: "mac-1", displayName: "M", cloudDeviceID: nil, home: nil),
            peer: LANAgentPeer(id: "phone-1", displayName: "P", controlAllowed: true),
            controlPermitted: { permitted.get() },
            heartbeatInterval: 0.05, silenceTimeout: 10, redactionIdleFlush: 0.05)
        let phone = Phone(channel: phoneEnd)
        let run = Task { await session.run() }
        _ = try unwrapOK(try await phone.request(.sessionResize, ["session_id": .string("s1"), "cols": .int(100), "rows": .int(30)]))
        permitted.set(false)
        let e = try unwrapError(try await phone.request(.sessionResize, ["session_id": .string("s1"), "cols": .int(100), "rows": .int(30)]))
        XCTAssertEqual(e.code, "control_not_allowed")
        XCTAssertEqual(backend.recordedControlCalls, ["resize s1 100x30"])
        await session.close(); _ = await run.value
    }

    // MARK: - control verbs

    func testInputResizeStartStopReachTheBackendWithTheRightArguments() async throws {
        let (session, phone, backend, run) = makeSession()
        _ = try unwrapOK(try await phone.request(.sessionInput, ["session_id": .string("s1"), "bytes_b64": .string(Data("ls\r".utf8).base64EncodedString())]))
        _ = try unwrapOK(try await phone.request(.sessionResize, ["session_id": .string("s1"), "cols": .int(120), "rows": .int(40)]))
        let started = try unwrapOK(try await phone.request(.sessionStart, ["provider": .string("claude"), "client_label": .string("phone"), "cwd": .string("/Users/t/proj"), "claude_remote_control": .bool(true)]))
        XCTAssertEqual(started["session_id"]?.stringValue, "new-1")
        _ = try unwrapOK(try await phone.request(.sessionStop, ["session_id": .string("s1")]))
        XCTAssertEqual(backend.recordedControlCalls, [
            "input s1 ls\r", "resize s1 120x40", "start claude label=phone cwd=/Users/t/proj rc=true", "stop s1",
        ])
        await session.close(); _ = await run.value
    }

    func testControlArgumentsAreValidatedBeforeTheHelper() async throws {
        let (session, phone, backend, run) = makeSession()
        let big = Data(repeating: 0x41, count: LANLinkProtocol.maxInputBytesPerFrame + 1).base64EncodedString()
        let c1 = try await errorCode(phone, .sessionInput, ["session_id": .string("s1"), "bytes_b64": .string(big)])
        XCTAssertEqual(c1, "bad_request")
        let c2 = try await errorCode(phone, .sessionInput, ["session_id": .string("s1"), "bytes_b64": .string("!!!")])
        XCTAssertEqual(c2, "bad_request")
        let c3 = try await errorCode(phone, .sessionInput, ["bytes_b64": .string("QQ==")])
        XCTAssertEqual(c3, "bad_request")
        let c4 = try await errorCode(phone, .sessionResize, ["session_id": .string("s1"), "cols": .int(0), "rows": .int(24)])
        XCTAssertEqual(c4, "bad_request")
        let c5 = try await errorCode(phone, .sessionResize, ["session_id": .string("s1"), "cols": .int(80), "rows": .int(5000)])
        XCTAssertEqual(c5, "bad_request")
        let c6 = try await errorCode(phone, .sessionStart, ["provider": .string("")])
        XCTAssertEqual(c6, "bad_request")
        let c7 = try await errorCode(phone, .sessionStart, ["provider": .string("claude"), "cwd": .string("relative")])
        XCTAssertEqual(c7, "bad_request")
        let c8 = try await errorCode(phone, .sessionStart, ["provider": .string("claude"), "client_label": .string(String(repeating: "x", count: 300))])
        XCTAssertEqual(c8, "bad_request")
        let c9 = try await errorCode(phone, .sessionStop, [:])
        XCTAssertEqual(c9, "bad_request")
        let c10 = try await errorCode(phone, .approvalDecide, ["session_id": .string("s1"), "approval_id": .string("a1"), "decision": .string("maybe")])
        XCTAssertEqual(c10, "bad_request")
        XCTAssertEqual(backend.recordedControlCalls, [])
        // Exactly the cap is fine.
        let max = Data(repeating: 0x41, count: LANLinkProtocol.maxInputBytesPerFrame).base64EncodedString()
        _ = try unwrapOK(try await phone.request(.sessionInput, ["session_id": .string("s1"), "bytes_b64": .string(max)]))
        XCTAssertEqual(backend.recordedControlCalls.count, 1)
        await session.close(); _ = await run.value
    }

    func testHelperErrorsOnControlVerbsAreTyped() async throws {
        let (session, phone, _, run) = makeSession()
        let e = try unwrapError(try await phone.request(.sessionInput, ["session_id": .string("nope"), "bytes_b64": .string("QQ==")]))
        XCTAssertEqual(e.asSessionControlError, .sessionNotFound)
        let e2 = try unwrapError(try await phone.request(.sessionStop, ["session_id": .string("nope")]))
        XCTAssertEqual(e2.asSessionControlError, .sessionNotFound)
        await session.close(); _ = await run.value
    }

    // MARK: - approvals

    func testApprovalsListIsRedactedAndDecideRoundTrips() async throws {
        let b = FakeStreamingBackend()
        b.pendingApprovals = [.fixture(id: "a1", summary: "curl -H 'Authorization: Bearer sk-ant-api03-AAAABBBBCCCCDDDD'",
                                        meta: ["command": "export ANTHROPIC_API_KEY=sk-ant-api03-EEEEFFFFGGGGHHHH"])]
        let (session, phone, backend, run) = makeSession(backend: b)
        let r = try unwrapOK(try await phone.request(.approvalsList, ["session_id": .string("s1")]))
        let rows = try XCTUnwrap(r["approvals"]?.arrayValue)
        XCTAssertEqual(rows.count, 1)
        let row = try XCTUnwrap(rows[0].objectValue)
        XCTAssertEqual(row["approval_id"]?.stringValue, "a1")
        XCTAssertEqual(row["session_id"]?.stringValue, "s1")
        XCTAssertEqual(row["title"]?.stringValue, "Bash")
        XCTAssertEqual(row["status"]?.stringValue, "pending")
        XCTAssertEqual(row["created_at"]?.intValue, 1_700_000_000)
        XCTAssertEqual(row["expires_at"]?.intValue, 1_700_000_060)
        let summary = try XCTUnwrap(row["summary"]?.stringValue)
        XCTAssertFalse(summary.contains("sk-ant-api03"), summary)
        XCTAssertTrue(summary.contains(LANEgressRedactor.redactionMarker))
        let meta = try XCTUnwrap(row["tool_metadata"]?.objectValue?["command"]?.stringValue)
        XCTAssertFalse(meta.contains("sk-ant-api03"), meta)

        _ = try unwrapOK(try await phone.request(.approvalDecide, ["session_id": .string("s1"), "approval_id": .string("a1"), "decision": .string("reject"), "comment": .string("no")]))
        XCTAssertEqual(backend.recordedControlCalls, ["decide s1 a1 reject no"])

        backend.approveError = SessionControlError.approvalAlreadyResolved
        let e = try unwrapError(try await phone.request(.approvalDecide, ["session_id": .string("s1"), "approval_id": .string("a1"), "decision": .string("approve")]))
        XCTAssertEqual(e.code, "approval_already_resolved")
        XCTAssertEqual(e.asSessionControlError, .approvalAlreadyResolved)
        await session.close(); _ = await run.value
    }

    func testApprovalEventsAreForwardedRedactedToAPermittedPeer() async throws {
        let (session, phone, backend, run) = makeSession()
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.push(.approvalRequested(approval: .fixture(id: "a2", summary: "token sk-ant-api03-AAAABBBBCCCCDDDD here")))
        backend.push(.approvalResolved(sessionId: "s1", approvalId: "a2", decision: "expired", status: "expired"))
        let f1 = await phone.nextEvent()
        guard case let .event(k1, _, _, d1) = f1 else { return XCTFail() }
        XCTAssertEqual(k1, "approval_requested")
        let a = try XCTUnwrap(d1["approval"]?.objectValue)
        XCTAssertEqual(a["approval_id"]?.stringValue, "a2")
        XCTAssertFalse(try XCTUnwrap(a["summary"]?.stringValue).contains("sk-ant-api03"))
        let f2 = await phone.nextEvent()
        guard case let .event(k2, _, _, d2) = f2 else { return XCTFail() }
        XCTAssertEqual(k2, "approval_resolved")
        XCTAssertEqual(d2["approval_id"]?.stringValue, "a2")
        XCTAssertEqual(d2["status"]?.stringValue, "expired")
        XCTAssertEqual(d2["session_id"]?.stringValue, "s1")
        await session.close(); _ = await run.value
    }

    func testApprovalEventsAreNotForwardedToAReadOnlyPeer() async throws {
        // An approval payload is a control surface; a peer that may not
        // decide does not get to see it.
        let (session, phone, backend, run) = makeSession(peer: nil)
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.push(.approvalRequested(approval: .fixture()))
        backend.push(.outputDelta(sessionId: "s1", payload: "marker\n", ts: 1))
        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, _) = f else { return XCTFail() }
        XCTAssertEqual(kind, "output", "an approval event leaked to a read-only peer")
        await session.close(); _ = await run.value
    }

    // MARK: - what the helper owns

    func testLocalOnlySessionsAreHiddenAndRefused() async throws {
        let b = FakeStreamingBackend()
        b.sessions = [
            SessionControlSummary(id: "s1", provider: "claude", clientLabel: "proj", status: "running"),
            SessionControlSummary(id: "att", provider: "claude", clientLabel: "my terminal", status: "running",
                                  attached: true, localOnly: true),
            SessionControlSummary(id: "shared", provider: "claude", clientLabel: "opted in", status: "running",
                                  attached: true, localOnly: false),
        ]
        let (session, phone, backend, run) = makeSession(backend: b)
        let r = try unwrapOK(try await phone.request(.sessionsList))
        let ids = r["sessions"]?.arrayValue?.compactMap { $0.objectValue?["id"]?.stringValue } ?? []
        XCTAssertEqual(ids, ["s1", "shared"], "a local-only attached session must not be listed")
        XCTAssertEqual(r["sessions"]?.arrayValue?[1].objectValue?["attached"]?.boolValue, true)
        for m: LANLinkProtocol.Method in [.sessionTail, .sessionSubscribe, .sessionInput, .sessionStop] {
            let e = try unwrapError(try await phone.request(m, ["session_id": .string("att"), "bytes_b64": .string("QQ==")]))
            XCTAssertEqual(e.code, "session_local_only", m.rawValue)
        }
        XCTAssertEqual(backend.recordedControlCalls, [])
        // An all-sessions subscription never carries the local-only session's bytes.
        _ = try unwrapOK(try await phone.request(.sessionSubscribe))
        backend.push(.outputDelta(sessionId: "att", payload: "secret terminal\n", ts: 1))
        backend.push(.outputDelta(sessionId: "s1", payload: "visible\n", ts: 1))
        let f = await phone.nextEvent()
        guard case let .event(_, _, _, d) = f else { return XCTFail() }
        XCTAssertEqual(d["session_id"]?.stringValue, "s1")
        await session.close(); _ = await run.value
    }

    func testRemoteControlOutcomeIsOnTheRowAndForwardedAsAnEvent() async throws {
        let b = FakeStreamingBackend()
        b.sessions = [SessionControlSummary(id: "s1", provider: "claude", clientLabel: "proj", status: "running",
                                            remoteControl: RemoteControlInfo(status: "ready", url: "https://claude.ai/code/abc123DEF", reason: nil))]
        let (session, phone, backend, run) = makeSession(backend: b)
        let r = try unwrapOK(try await phone.request(.sessionsList))
        let rc = try XCTUnwrap(r["sessions"]?.arrayValue?[0].objectValue?["remote_control"]?.objectValue)
        XCTAssertEqual(rc["status"]?.stringValue, "ready")
        XCTAssertEqual(rc["url"]?.stringValue, "https://claude.ai/code/abc123DEF")
        _ = try unwrapOK(try await phone.request(.sessionSubscribe, ["session_id": .string("s1")]))
        backend.push(.sessionRemoteControl(sessionId: "s1", status: "unavailable", url: nil, reason: "disabled_by_policy"))
        let f = await phone.nextEvent()
        guard case let .event(kind, _, _, d) = f else { return XCTFail() }
        XCTAssertEqual(kind, "session_remote_control")
        XCTAssertEqual(d["status"]?.stringValue, "unavailable")
        XCTAssertEqual(d["reason"]?.stringValue, "disabled_by_policy")
        await session.close(); _ = await run.value
    }

    // MARK: - liveness under a slow helper

    func testASlowBackendCallDoesNotGetThePhoneDisconnected() async throws {
        // Requests are processed off the inbound loop: while the helper
        // takes 0.6 s to answer `sessions.list`, the phone's heartbeats
        // must still count as inbound traffic against a 0.25 s cutoff.
        let b = FakeStreamingBackend()
        b.listDelay = 0.6
        let (session, phone, _, run) = makeSession(backend: b, heartbeat: 0.05, silence: 0.25)
        let beats = Task {
            for _ in 0..<12 { try await phone.heartbeat(); try await Task.sleep(nanoseconds: 60_000_000) }
        }
        let r = try unwrapOK(try await phone.request(.sessionsList))
        XCTAssertEqual(r["sessions"]?.arrayValue?.count, 1)
        _ = try? await beats.value
        XCTAssertFalse(phone.ended, "phone was dropped as silent while the helper was slow")
        await session.close(); _ = await run.value
    }

    func testRequestsAreAnsweredInOrder() async throws {
        // Input frames must reach the helper in the order sent even
        // though they are processed off the inbound loop.
        let (session, phone, backend, run) = makeSession()
        var ids: [String] = []
        for i in 0..<20 {
            let id = UUID().uuidString; ids.append(id)
            try await phone.channel.send(try LANLinkFrame.request(id: id, method: "session.input",
                params: ["session_id": .string("s1"), "bytes_b64": .string(Data("k\(i)".utf8).base64EncodedString())]).encode())
        }
        for id in ids { _ = try unwrapOK(await phone.reply(for: id)) }
        XCTAssertEqual(backend.recordedControlCalls, (0..<20).map { "input s1 k\($0)" })
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
        // Wait FOR two heartbeats rather than sleeping a fixed interval and
        // counting: on CI's slower runner a 150 ms sleep saw only one 30 ms
        // tick, because each tick also awaits the backend's gate check.
        let (session, phone, _, run) = makeSession(heartbeat: 0.03)
        let deadline = Date().addingTimeInterval(3)
        var count = 0
        while count < 2, Date() < deadline {
            count = phone.allFrames.filter { if case .heartbeat = $0 { return true }; return false }.count
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThanOrEqual(count, 2, "fewer than two heartbeats in 3 s")
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
        // The product's margin is 1 s beats against a 3 s cutoff. The test
        // keeps the same 3× ratio at a scale a loaded CI runner can honour:
        // 40 ms beats against a 100 ms cutoff let one late wake-up
        // disconnect the phone, which then failed with "closed" on its next
        // send — a harness artifact, not the agent misbehaving.
        let (session, phone, _, run) = makeSession(heartbeat: 0.05, silence: 1.0)
        for _ in 0..<8 {
            try await phone.heartbeat()
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        // 1.2 s of beats, every one well inside the 1 s window.
        XCTAssertFalse(phone.ended, "heartbeating phone was disconnected")
        await session.close(); _ = await run.value
    }
}
