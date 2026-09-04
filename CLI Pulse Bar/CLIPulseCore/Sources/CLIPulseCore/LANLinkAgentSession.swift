import Foundation

/// What the agent says about itself in `hello`.
public struct LANAgentIdentity: Sendable, Equatable {
    /// Local pairing identity — the `did` in the Bonjour TXT and the QR.
    public let deviceID: String
    /// Human name shown on the phone ("Jason's MacBook Pro").
    public let displayName: String
    /// `devices.id` IF this Mac is cloud-registered; nil otherwise. Sent
    /// only inside the encrypted channel so the phone can cross-check
    /// against its `state.devices` — never in the TXT record.
    public let cloudDeviceID: String?
    /// M1: the Mac user's home directory, so the phone can prefill a
    /// working directory. Inside the encrypted channel only.
    public let home: String?

    public init(deviceID: String, displayName: String, cloudDeviceID: String?, home: String? = nil) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.cloudDeviceID = cloudDeviceID
        self.home = home
    }
}

/// M1: the paired phone on the other end of one connection, as proven in
/// `hello` (the phone sends its `did` plus an HMAC over the connection's
/// exporter, keyed by the per-peer session key — see
/// `LANPairing.peerBindingProof`). nil means "not proven yet, or proof
/// failed", and such a connection is read-only.
public struct LANAgentPeer: Sendable, Equatable {
    public let id: String
    public let displayName: String
    /// The stored permission at attribution time. The live answer comes
    /// from `controlPermitted`, re-asked on every control request.
    public let controlAllowed: Bool

    public init(id: String, displayName: String, controlAllowed: Bool) {
        self.id = id
        self.displayName = displayName
        self.controlAllowed = controlAllowed
    }
}

/// One phone's connection to the agent, from handshake-complete to close.
///
/// This is the whole "agent" as far as a connection is concerned: it
/// decodes frames, checks what the peer may do, forwards reads and
/// (M1) control verbs to the helper-backed `SessionControlling`, and — the
/// part that matters — is the ONLY path by which terminal bytes and
/// approval payloads reach the network, so it is where redaction happens.
///
/// Written against `LANLinkChannel` and `SessionControlling`, not against
/// sockets or the UDS client, so `LANLinkAgentSessionTests` runs the real
/// router over an in-memory channel with a scripted backend and asserts
/// on the frames that come out.
///
/// ── Requests are processed off the inbound loop ──
/// The inbound loop only decodes and enqueues; one worker task answers
/// requests in order. A helper round trip that takes seconds (a spawn, a
/// hung `hello`) therefore never stops heartbeats from being read, and
/// input frames still reach the PTY in the order they were sent.
///
/// ── Liveness, both directions ──
/// The helper never sends heartbeats, so this session does: one every
/// `heartbeatInterval`, BEFORE the gate check so a slow helper cannot
/// starve them. It also EXPECTS the phone to send them, and closes after
/// `silenceTimeout` without any inbound frame.
///
/// ── The user's revocation levers ──
/// On every heartbeat tick the session re-asks the backend whether local
/// control is still enabled; off ⇒ every subscription ends with
/// `local_control_disabled` and the connection closes. Fail closed: if
/// the backend cannot be asked, the answer is "no". Per phone, the Mac
/// user can withdraw CONTROL without cutting the link: `controlPermitted`
/// is asked on every M1 verb, so the toggle applies to the very next
/// frame.
///
/// ── What the helper does not own ──
/// A hand-launched session parked in tmux is local-only until the user
/// opts it in. Such sessions are not listed, not readable, not
/// controllable over the link, and their bytes are dropped from an
/// all-sessions subscription.
public actor LANLinkAgentSession {

    public enum EndReason: Equatable, Sendable {
        case peerClosed
        case peerSilent
        case localControlDisabled
        case helperGone
        case protocolViolation(String)
        case transportError(String)
        case closedByAgent
    }

    private let channel: any LANLinkChannel
    private let backend: any SessionControlling
    private let identity: LANAgentIdentity
    /// The proven peer, or nil until a valid binding arrives in `hello`.
    /// Set once, inside the actor, from the hello handler.
    private var peer: LANAgentPeer?
    /// Given (did, proof, exporter), returns the peer if the proof matches
    /// the stored key for `did`. The agent calls this once, in hello.
    private let authenticatePeer: @Sendable (String, Data, Data) async -> LANAgentPeer?
    private let controlPermitted: @Sendable () async -> Bool
    private let heartbeatInterval: TimeInterval
    private let silenceTimeout: TimeInterval
    private let redactionIdleFlush: TimeInterval
    private let clock: @Sendable () -> Date

    private var lastInbound: Date
    private var ended: EndReason?
    private var heartbeatTask: Task<Void, Never>?

    private struct Request: Sendable {
        let id: String
        let method: String
        let params: [String: AnySendableJSON]
    }
    private var requestQueue: AsyncStream<Request>.Continuation?
    private var workerTask: Task<Void, Never>?

    private struct Subscription {
        let sessionID: String?
        var task: Task<Void, Never>?
        var flushTask: Task<Void, Never>?
        var redactor = LANEgressRedactor.Streaming()
        var seq: UInt64 = 0
    }
    private var subscriptions: [String: Subscription] = [:]

    /// Rows as last seen from the helper; the local-only set is derived
    /// from it. Refreshed on `sessions.list`, on a session-scoped verb for
    /// an id not yet seen, and when the helper announces a new session.
    private var knownRows: [String: SessionControlSummary] = [:]
    private var rowsLoaded = false

    public init(
        channel: any LANLinkChannel,
        backend: any SessionControlling,
        identity: LANAgentIdentity,
        peer: LANAgentPeer? = nil,
        authenticatePeer: (@Sendable (String, Data, Data) async -> LANAgentPeer?)? = nil,
        controlPermitted: (@Sendable () async -> Bool)? = nil,
        heartbeatInterval: TimeInterval = LANLinkProtocol.heartbeatInterval,
        silenceTimeout: TimeInterval = LANLinkProtocol.peerSilenceTimeout,
        redactionIdleFlush: TimeInterval = 0.15,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.channel = channel
        self.backend = backend
        self.identity = identity
        // Tests inject a pre-proven `peer`; production leaves it nil and it
        // is set by the hello proof. `authenticatePeer` nil ⇒ no binding
        // path (the injected peer, or read-only).
        self.peer = peer
        self.authenticatePeer = authenticatePeer ?? { _, _, _ in nil }
        let stored = peer?.controlAllowed ?? false
        self.controlPermitted = controlPermitted ?? { stored }
        self.heartbeatInterval = heartbeatInterval
        self.silenceTimeout = silenceTimeout
        self.redactionIdleFlush = redactionIdleFlush
        self.clock = clock
        self.lastInbound = clock()
    }

    // MARK: - Lifecycle

    /// Drive the connection until it ends. Returns why.
    public func run() async -> EndReason {
        startHeartbeat()
        startWorker()
        do {
            for try await body in channel.inbound {
                if ended != nil { break }
                lastInbound = clock()
                await handleInbound(body)
            }
            if ended == nil { await end(.peerClosed) }
        } catch {
            if ended == nil { await end(.transportError("\(error)")) }
        }
        return ended ?? .peerClosed
    }

    /// Close from the agent side (app quitting, agent turned off, the
    /// phone forgotten).
    public func close() async {
        await end(.closedByAgent)
    }

    private func end(_ reason: EndReason) async {
        guard ended == nil else { return }
        ended = reason
        heartbeatTask?.cancel()
        heartbeatTask = nil
        requestQueue?.finish()
        workerTask?.cancel()
        let endReason: LANLinkProtocol.SubscriptionEndReason
        switch reason {
        case .localControlDisabled: endReason = .localControlDisabled
        case .helperGone: endReason = .helperGone
        default: endReason = .clientRequested
        }
        for id in Array(subscriptions.keys) {
            await endSubscription(id, reason: endReason, notify: reason == .localControlDisabled || reason == .helperGone)
        }
        channel.close()
    }

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(await self.heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        guard ended == nil else { return }

        if clock().timeIntervalSince(lastInbound) > silenceTimeout {
            await end(.peerSilent)
            return
        }

        // Beat first: a slow helper must not stop the phone from seeing
        // that this end is alive.
        try? await send(.heartbeat(ts: clock().timeIntervalSince1970))

        // Revocation check — fail closed.
        let enabled = (try? await backend.isLocalControlEnabled()) ?? false
        if !enabled {
            await end(.localControlDisabled)
        }
    }

    private func startWorker() {
        let (stream, continuation) = AsyncStream.makeStream(of: Request.self)
        requestQueue = continuation
        workerTask = Task { [weak self] in
            for await req in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handleRequest(id: req.id, method: req.method, params: req.params)
            }
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ body: Data) async {
        let frame: LANLinkFrame
        do {
            frame = try LANLinkFrame.decode(body)
        } catch {
            await end(.protocolViolation("undecodable frame: \(error)"))
            return
        }
        switch frame {
        case .heartbeat:
            return
        case let .request(id, method, params):
            requestQueue?.yield(Request(id: id, method: method, params: params))
        case .reply, .event:
            // A client never sends these. Treat as hostile.
            await end(.protocolViolation("client sent a server-only frame"))
        }
    }

    private func handleRequest(id: String, method: String, params: [String: AnySendableJSON]) async {
        guard ended == nil else { return }
        guard let m = LANLinkProtocol.Method(rawValue: method) else {
            await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "unknown method: \(method)")
            return
        }
        if m.isM1 {
            // Asked every time: the Mac user's per-phone toggle applies to
            // the very next frame, and an unattributed connection never
            // gets past here.
            guard peer != nil, await controlPermitted() else {
                await reply(id, error: LANLinkProtocol.ErrorCode.controlNotAllowed,
                            "this phone may not control sessions on this Mac")
                return
            }
        }
        do {
            switch m {
            case .hello:
                await authenticateFromHello(params)
                await reply(id, result: await helloResult())
            case .ping:
                await reply(id, result: ["ts": .double(clock().timeIntervalSince1970)])
            case .sessionsList:
                try await refreshRows()
                let rows = knownRows.values.filter { !$0.localOnly }
                    .sorted { $0.id < $1.id }
                await reply(id, result: ["sessions": .array(rows.map(Self.encode))])
            case .sessionTail:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' required")
                    return
                }
                if try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                let maxBytes = params["max_bytes"]?.intValue ?? 8192
                let raw = try await backend.getTailSnapshot(sessionId: sid, maxBytes: maxBytes)
                // The helper redacts the snapshot already; egress redacts
                // again unconditionally (idempotent) so this path does not
                // depend on which helper answered.
                let text = String(decoding: raw, as: UTF8.self)
                let redacted = LANEgressRedactor.redact(text)
                await reply(id, result: [
                    "session_id": .string(sid),
                    "bytes_b64": .string(Data(redacted.utf8).base64EncodedString()),
                ])
            case .sessionSubscribe:
                let sid = params["session_id"]?.stringValue
                if let sid, try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                guard subscriptions.count < LANLinkProtocol.maxSubscriptionsPerConnection else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.subscriptionLimit,
                                "at most \(LANLinkProtocol.maxSubscriptionsPerConnection) subscriptions")
                    return
                }
                let sub = UUID().uuidString.lowercased()
                subscriptions[sub] = Subscription(sessionID: sid)
                // Subscribe to the backend BEFORE replying. The reply is
                // the phone's signal that events may now arrive; if the
                // backend subscription happened after it, anything emitted
                // in that gap would be lost. Found as a 5-minute hang under
                // full-suite load: the test pushed events between the reply
                // and the subscription and then waited for them forever.
                startSubscription(sub, sessionID: sid)
                await reply(id, result: ["sub": .string(sub)])
            case .sessionUnsubscribe:
                guard let sub = params["sub"]?.stringValue, subscriptions[sub] != nil else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.subscriptionNotFound, "no such subscription")
                    return
                }
                await endSubscription(sub, reason: .clientRequested, notify: false)
                await reply(id, result: [:])

            // ── M1: control ──
            case .sessionInput:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' required"); return
                }
                guard let b64 = params["bytes_b64"]?.stringValue, let bytes = Data(base64Encoded: b64) else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'bytes_b64' must be base64"); return
                }
                guard bytes.count <= LANLinkProtocol.maxInputBytesPerFrame else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest,
                                "input frame over \(LANLinkProtocol.maxInputBytesPerFrame) bytes"); return
                }
                if try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                try await backend.sendInputRaw(sessionId: sid, bytes: bytes)
                await reply(id, result: ["session_id": .string(sid), "written": .int(bytes.count)])
            case .sessionResize:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' required"); return
                }
                guard let cols = params["cols"]?.intValue, let rows = params["rows"]?.intValue,
                      (1...1000).contains(cols), (1...1000).contains(rows) else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'cols' and 'rows' must be 1…1000"); return
                }
                if try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                try await backend.resize(sessionId: sid, cols: cols, rows: rows)
                await reply(id, result: ["session_id": .string(sid), "cols": .int(cols), "rows": .int(rows)])
            case .sessionStart:
                guard let provider = params["provider"]?.stringValue, !provider.isEmpty, provider.utf8.count <= 32 else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'provider' required"); return
                }
                let label = params["client_label"]?.stringValue
                if let label, label.utf8.count > 256 {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'client_label' must be at most 256 bytes"); return
                }
                let cwd = params["cwd"]?.stringValue
                if let cwd, !cwd.hasPrefix("/") || cwd.utf8.count > 1024 {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'cwd' must be an absolute path"); return
                }
                let rc = params["claude_remote_control"]?.boolValue ?? false
                let started = try await backend.startManagedSession(
                    provider: provider, clientLabel: label, cwd: cwd, claudeRemoteControl: rc)
                rowsLoaded = false   // the next list must see the new row
                await reply(id, result: ["session_id": .string(started.sessionId)])
            case .sessionStop:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' required"); return
                }
                if try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                try await backend.stopSession(sessionId: sid)
                await reply(id, result: ["session_id": .string(sid), "stopped": .bool(true)])
            case .approvalsList:
                let sid = params["session_id"]?.stringValue
                if let sid, try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                let rows = try await backend.getPendingApprovals(sessionId: sid)
                    .filter { !(knownRows[$0.sessionId]?.localOnly ?? false) }
                await reply(id, result: ["approvals": .array(rows.map(Self.encode))])
            case .approvalDecide:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty,
                      let aid = params["approval_id"]?.stringValue, !aid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' and 'approval_id' required"); return
                }
                guard let decision = params["decision"]?.stringValue.flatMap(ApprovalDecision.init(rawValue:)) else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'decision' must be approve or reject"); return
                }
                let comment = params["comment"]?.stringValue
                if let comment, comment.utf8.count > 1024 {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'comment' must be at most 1024 bytes"); return
                }
                if try await isLocalOnly(sid) { await replyLocalOnly(id); return }
                try await backend.approveAction(sessionId: sid, approvalId: aid, decision: decision, comment: comment)
                await reply(id, result: ["session_id": .string(sid), "approval_id": .string(aid), "decision": .string(decision.rawValue)])
            }
        } catch let e as SessionControlError {
            await reply(id, error: Self.wireCode(for: e), e.description)
        } catch {
            await reply(id, error: LANLinkProtocol.ErrorCode.internalError, "\(error)")
        }
    }

    /// The binding proof, if the phone sent one and it matches a stored
    /// peer for the claimed `did`. Sets `self.peer` once. A phone that
    /// sends nothing, or a bad proof, stays read-only.
    private func authenticateFromHello(_ params: [String: AnySendableJSON]) async {
        guard peer == nil,
              let did = params["did"]?.stringValue, !did.isEmpty,
              let proofB64 = params["proof"]?.stringValue, let proof = Data(base64Encoded: proofB64),
              let exporter = channel.exporterSecret(label: LANPairing.peerBindingExporterLabel)
        else { return }
        if let authed = await authenticatePeer(did, proof, exporter) {
            peer = authed
        }
    }

    private func replyLocalOnly(_ id: String) async {
        await reply(id, error: LANLinkProtocol.ErrorCode.sessionLocalOnly,
                    "that session was not started by CLI Pulse and is not shared")
    }

    // MARK: - Rows the helper owns

    private func refreshRows() async throws {
        let rows = try await backend.listSessions()
        knownRows = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        rowsLoaded = true
    }

    /// Fail closed on the OTHER side of "unknown": a session id the helper
    /// has not listed is treated as not local-only, so a session that was
    /// just spawned is usable — the helper itself still refuses ids it
    /// does not own.
    private func isLocalOnly(_ sid: String) async throws -> Bool {
        if !rowsLoaded || knownRows[sid] == nil { try await refreshRows() }
        return knownRows[sid]?.localOnly ?? false
    }

    private func helloResult() async -> [String: AnySendableJSON] {
        var helper: [String: AnySendableJSON] = ["reachable": .bool(false)]
        if let h = try? await backend.hello() {
            helper["reachable"] = .bool(true)
            helper["version"] = .string(h.helperVersion)
            if let impl = h.implementation { helper["implementation"] = .string(impl) }
            let enabled = (try? await backend.isLocalControlEnabled()) ?? false
            helper["local_control"] = .bool(enabled)
            helper["provider_availability"] = .array(h.providerAvailability.map { .string($0) })
            if let rc = h.claudeRemoteControl {
                helper["claude_remote_control"] = .object(rc.mapValues { .string($0) })
            }
        }
        let permitted = await controlPermitted()
        let control = peer != nil && permitted
        let methods: Set<LANLinkProtocol.Method> = control
            ? Set(LANLinkProtocol.Method.allCases) : LANLinkProtocol.Method.readOnly
        var r: [String: AnySendableJSON] = [
            "v": .int(LANLinkProtocol.version),
            "did": .string(identity.deviceID),
            "name": .string(identity.displayName),
            "capabilities": .object([
                "read_only": .bool(!control),
                "control": .bool(control),
                "approvals": .bool(control),
                "start": .bool(control),
                "subscribe": .bool(true),
                "tail": .bool(true),
            ]),
            "methods": .array(methods.map(\.rawValue).sorted().map { .string($0) }),
            "helper": .object(helper),
        ]
        if let cloud = identity.cloudDeviceID { r["cloud_device_id"] = .string(cloud) }
        if let home = identity.home { r["home"] = .string(home) }
        if let peer {
            r["peer"] = .object([
                "id": .string(peer.id),
                "name": .string(peer.displayName),
                "control_allowed": .bool(control),
            ])
        }
        return r
    }

    // MARK: - Subscriptions

    private func startSubscription(_ sub: String, sessionID: String?) {
        let stream = backend.subscribeEvents(sessionId: sessionID)
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in stream {
                    if Task.isCancelled { return }
                    await self.forward(sub, event)
                }
                await self.endSubscription(sub, reason: .sessionGone, notify: true)
            } catch {
                if Task.isCancelled { return }
                await self.endSubscription(sub, reason: .helperGone, notify: true)
            }
        }
        subscriptions[sub]?.task = task
    }

    private func forward(_ sub: String, _ event: LocalSessionEvent) async {
        guard subscriptions[sub] != nil else { return }
        switch event {
        case .subscribed:
            // The ack. The phone lists sessions separately; nothing to
            // forward, but it does mean the stream is live.
            return
        case let .outputDelta(sid, payload, ts), let .outputRaw(sid, payload, ts):
            if (try? await isLocalOnly(sid)) ?? false { return }
            await emitOutput(sub, sessionID: sid, text: payload, ts: ts)
        case let .sessionStarted(sid, provider, label):
            // A new row: learn whether it is local-only BEFORE saying so.
            rowsLoaded = false
            if (try? await isLocalOnly(sid)) ?? false { return }
            var d: [String: AnySendableJSON] = ["session_id": .string(sid), "provider": .string(provider)]
            if let label { d["client_label"] = .string(label) }
            await emit(sub, kind: .sessionStarted, data: d)
        case let .sessionStatus(sid, status):
            if knownRows[sid]?.localOnly ?? false { return }
            await emit(sub, kind: .sessionStatus, data: ["session_id": .string(sid), "status": .string(status)])
        case let .sessionStopped(sid, code):
            if knownRows[sid]?.localOnly ?? false { return }
            var d: [String: AnySendableJSON] = ["session_id": .string(sid)]
            if let code { d["exit_code"] = .int(code) }
            await flushOutput(sub)
            await emit(sub, kind: .sessionStopped, data: d)
        case let .approvalRequested(approval):
            // A control surface: only a peer that may decide sees it.
            guard peer != nil, await controlPermitted() else { return }
            if knownRows[approval.sessionId]?.localOnly ?? false { return }
            await emit(sub, kind: .approvalRequested, data: ["session_id": .string(approval.sessionId), "approval": Self.encode(approval)])
        case let .approvalResolved(sid, aid, decision, status):
            guard peer != nil, await controlPermitted() else { return }
            await emit(sub, kind: .approvalResolved, data: [
                "session_id": .string(sid), "approval_id": .string(aid),
                "decision": .string(decision), "status": .string(status),
            ])
        case let .sessionRemoteControl(sid, status, url, reason):
            if knownRows[sid]?.localOnly ?? false { return }
            rowsLoaded = false   // the row's remote_control changed
            var d: [String: AnySendableJSON] = ["session_id": .string(sid), "status": .string(status)]
            if let url { d["url"] = .string(url) }
            if let reason { d["reason"] = .string(reason) }
            await emit(sub, kind: .sessionRemoteControl, data: d)
        case .heartbeat, .other:
            return
        case .error:
            await endSubscription(sub, reason: .helperGone, notify: true)
        }
    }

    /// Output goes through the streaming redactor. Whatever it holds
    /// back is flushed by an idle timer, so an interactive prompt that
    /// ends without a newline ("proceed? (y/n)") still reaches the phone
    /// promptly — a chunk-boundary split arrives microseconds apart, so
    /// a 150 ms idle window does not reopen that hole.
    private func emitOutput(_ sub: String, sessionID: String, text: String, ts: TimeInterval) async {
        guard var s = subscriptions[sub] else { return }
        let ready = s.redactor.submit(text)
        s.flushTask?.cancel()
        s.flushTask = Task { [weak self, idle = redactionIdleFlush] in
            try? await Task.sleep(nanoseconds: UInt64(idle * 1_000_000_000))
            if Task.isCancelled { return }
            await self?.flushOutput(sub)
        }
        subscriptions[sub] = s
        if !ready.isEmpty {
            await emit(sub, kind: .output, data: [
                "session_id": .string(sessionID),
                "bytes_b64": .string(Data(ready.utf8).base64EncodedString()),
                "ts": .double(ts),
            ])
        }
    }

    private func flushOutput(_ sub: String) async {
        guard var s = subscriptions[sub], s.redactor.hasPendingBytes else { return }
        let tail = s.redactor.flush()
        s.flushTask = nil
        subscriptions[sub] = s
        if !tail.isEmpty {
            await emit(sub, kind: .output, data: [
                "session_id": .string(s.sessionID ?? ""),
                "bytes_b64": .string(Data(tail.utf8).base64EncodedString()),
                "ts": .double(clock().timeIntervalSince1970),
            ])
        }
    }

    private func endSubscription(_ sub: String, reason: LANLinkProtocol.SubscriptionEndReason, notify: Bool) async {
        guard var s = subscriptions[sub] else { return }
        s.task?.cancel()
        s.flushTask?.cancel()
        // Flush whatever the redactor holds before saying goodbye.
        let tail = s.redactor.flush()
        subscriptions[sub] = s
        if !tail.isEmpty, ended == nil {
            await emit(sub, kind: .output, data: [
                "session_id": .string(s.sessionID ?? ""),
                "bytes_b64": .string(Data(tail.utf8).base64EncodedString()),
                "ts": .double(clock().timeIntervalSince1970),
            ])
        }
        if notify, ended == nil || reason == .localControlDisabled || reason == .helperGone {
            await emit(sub, kind: .subscriptionEnded, data: ["reason": .string(reason.rawValue)])
        }
        subscriptions[sub] = nil
    }

    private func emit(_ sub: String, kind: LANLinkProtocol.EventKind, data: [String: AnySendableJSON]) async {
        guard var s = subscriptions[sub] else { return }
        s.seq += 1
        subscriptions[sub] = s
        try? await send(.event(kind: kind.rawValue, subscription: sub, seq: s.seq, data: data))
    }

    // MARK: - Outbound

    private func reply(_ id: String, result: [String: AnySendableJSON]) async {
        try? await send(.reply(id: id, ok: true, result: result, error: nil))
    }

    private func reply(_ id: String, error code: String, _ message: String) async {
        try? await send(.reply(id: id, ok: false, result: [:],
                               error: LANLinkWireError(code: code, message: message)))
    }

    private func send(_ frame: LANLinkFrame) async throws {
        let body = try frame.encode()
        try await channel.send(body)
    }

    // MARK: - Encoding helpers

    static func encode(_ row: SessionControlSummary) -> AnySendableJSON {
        var d: [String: AnySendableJSON] = [
            "id": .string(row.id),
            "provider": .string(row.provider),
            "status": .string(row.status),
            "controllable": .bool(row.controllable),
            "source": .string(row.source.rawValue),
            "attached": .bool(row.attached),
        ]
        if let l = row.clientLabel { d["client_label"] = .string(l) }
        if let rc = row.remoteControl {
            var r: [String: AnySendableJSON] = ["status": .string(rc.status)]
            if let u = rc.url { r["url"] = .string(u) }
            if let why = rc.reason { r["reason"] = .string(why) }
            d["remote_control"] = .object(r)
        }
        return .object(d)
    }

    /// An approval as the phone sees it: every free-text field goes
    /// through the egress redactor. Tool input (a Bash command line, a
    /// file path, a URL with a token in it) is exactly where secrets sit.
    static func encode(_ a: PendingApproval) -> AnySendableJSON {
        var d: [String: AnySendableJSON] = [
            "approval_id": .string(a.approvalId),
            "session_id": .string(a.sessionId),
            "type": .string(a.type),
            "title": .string(LANEgressRedactor.redact(a.title)),
            "summary": .string(LANEgressRedactor.redact(a.summary)),
            "tool_metadata": .object(a.toolMetadata.mapValues { .string(LANEgressRedactor.redact($0)) }),
            "status": .string(a.status),
            "created_at": .double(a.createdAt.timeIntervalSince1970),
        ]
        if let exp = a.expiresAt { d["expires_at"] = .double(exp.timeIntervalSince1970) }
        return .object(d)
    }

    static func wireCode(for e: SessionControlError) -> String {
        switch e {
        case .helperNotRunning, .runtimeRestricted: return LANLinkProtocol.ErrorCode.helperNotRunning
        case .unauthenticated: return LANLinkProtocol.ErrorCode.unauthenticated
        case .versionMismatch: return LANLinkProtocol.ErrorCode.versionMismatch
        case .notImplemented: return LANLinkProtocol.ErrorCode.notImplemented
        case .localControlOff: return LANLinkProtocol.ErrorCode.localControlOff
        case .sessionNotFound: return LANLinkProtocol.ErrorCode.sessionNotFound
        case .invalidResponse: return LANLinkProtocol.ErrorCode.badRequest
        case .notControllable: return "not_controllable"
        case .approvalNotFound: return "approval_not_found"
        case .approvalExpired: return "approval_expired"
        case .approvalAlreadyResolved: return "approval_already_resolved"
        case .approvalNotAllowed: return "approval_not_allowed"
        case .approvalCapabilityInvalid: return "approval_capability_invalid"
        case .approvalLimitReached: return "approval_limit_reached"
        default: return LANLinkProtocol.ErrorCode.internalError
        }
    }
}
