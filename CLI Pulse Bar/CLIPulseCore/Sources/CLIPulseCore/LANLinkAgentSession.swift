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

    public init(deviceID: String, displayName: String, cloudDeviceID: String?) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.cloudDeviceID = cloudDeviceID
    }
}

/// One phone's connection to the agent, from handshake-complete to close.
///
/// This is the whole "agent" as far as a connection is concerned: it
/// decodes frames, refuses what M0 does not offer, forwards reads to the
/// helper-backed `SessionEventStreaming`, and — the part that matters —
/// is the ONLY path by which terminal bytes reach the network, so it is
/// where redaction happens.
///
/// Written against `LANLinkChannel` and `SessionEventStreaming`, not
/// against sockets or the UDS client, so `LANLinkAgentSessionTests` runs
/// the real router over an in-memory channel with a scripted backend and
/// asserts on the frames that come out.
///
/// ── Liveness, both directions ──
/// The helper never sends heartbeats, so this session does: one every
/// `heartbeatInterval`. It also EXPECTS the phone to send them, and
/// closes after `silenceTimeout` without any inbound frame — that is
/// what makes "Mac drops off Wi-Fi ⇒ phone shows disconnected in 3 s"
/// symmetric.
///
/// ── The user's revocation lever ──
/// On every heartbeat tick the session re-asks the backend whether local
/// control is still enabled. The helper only checks that gate once,
/// before the subscription ack; without this, turning the toggle off on
/// the Mac would leave every phone stream running. When it flips off,
/// every subscription is ended with `local_control_disabled` and the
/// connection is closed. Fail closed: if the backend cannot be asked,
/// the answer is treated as "no".
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
    private let backend: any SessionEventStreaming
    private let identity: LANAgentIdentity
    private let heartbeatInterval: TimeInterval
    private let silenceTimeout: TimeInterval
    private let redactionIdleFlush: TimeInterval
    private let clock: @Sendable () -> Date

    private var lastInbound: Date
    private var ended: EndReason?
    private var heartbeatTask: Task<Void, Never>?

    private struct Subscription {
        let sessionID: String?
        var task: Task<Void, Never>?
        var flushTask: Task<Void, Never>?
        var redactor = LANEgressRedactor.Streaming()
        var seq: UInt64 = 0
    }
    private var subscriptions: [String: Subscription] = [:]

    public init(
        channel: any LANLinkChannel,
        backend: any SessionEventStreaming,
        identity: LANAgentIdentity,
        heartbeatInterval: TimeInterval = LANLinkProtocol.heartbeatInterval,
        silenceTimeout: TimeInterval = LANLinkProtocol.peerSilenceTimeout,
        redactionIdleFlush: TimeInterval = 0.15,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.channel = channel
        self.backend = backend
        self.identity = identity
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

    /// Close from the agent side (app quitting, agent turned off).
    public func close() async {
        await end(.closedByAgent)
    }

    private func end(_ reason: EndReason) async {
        guard ended == nil else { return }
        ended = reason
        heartbeatTask?.cancel()
        heartbeatTask = nil
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

        // Revocation check — fail closed.
        let enabled = (try? await backend.isLocalControlEnabled()) ?? false
        if !enabled {
            await end(.localControlDisabled)
            return
        }

        try? await send(.heartbeat(ts: clock().timeIntervalSince1970))
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
            await handleRequest(id: id, method: method, params: params)
        case .reply, .event:
            // A client never sends these. Treat as hostile.
            await end(.protocolViolation("client sent a server-only frame"))
        }
    }

    private func handleRequest(id: String, method: String, params: [String: AnySendableJSON]) async {
        guard let m = LANLinkProtocol.Method(rawValue: method) else {
            await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "unknown method: \(method)")
            return
        }
        guard m.isReadOnly else {
            await reply(id, error: LANLinkProtocol.ErrorCode.notImplemented,
                        "\(method) is not available in this version")
            return
        }
        do {
            switch m {
            case .hello:
                await reply(id, result: await helloResult())
            case .ping:
                await reply(id, result: ["ts": .double(clock().timeIntervalSince1970)])
            case .sessionsList:
                let rows = try await backend.listSessions()
                await reply(id, result: ["sessions": .array(rows.map(Self.encode))])
            case .sessionTail:
                guard let sid = params["session_id"]?.stringValue, !sid.isEmpty else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.badRequest, "'session_id' required")
                    return
                }
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
                guard subscriptions.count < LANLinkProtocol.maxSubscriptionsPerConnection else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.subscriptionLimit,
                                "at most \(LANLinkProtocol.maxSubscriptionsPerConnection) subscriptions")
                    return
                }
                let sub = UUID().uuidString.lowercased()
                subscriptions[sub] = Subscription(sessionID: sid)
                await reply(id, result: ["sub": .string(sub)])
                startSubscription(sub, sessionID: sid)
            case .sessionUnsubscribe:
                guard let sub = params["sub"]?.stringValue, subscriptions[sub] != nil else {
                    await reply(id, error: LANLinkProtocol.ErrorCode.subscriptionNotFound, "no such subscription")
                    return
                }
                await endSubscription(sub, reason: .clientRequested, notify: false)
                await reply(id, result: [:])
            default:
                await reply(id, error: LANLinkProtocol.ErrorCode.notImplemented, "\(method)")
            }
        } catch let e as SessionControlError {
            await reply(id, error: Self.wireCode(for: e), e.description)
        } catch {
            await reply(id, error: LANLinkProtocol.ErrorCode.internalError, "\(error)")
        }
    }

    private func helloResult() async -> [String: AnySendableJSON] {
        var helper: [String: AnySendableJSON] = ["reachable": .bool(false)]
        if let h = try? await backend.hello() {
            helper["reachable"] = .bool(true)
            helper["version"] = .string(h.helperVersion)
            if let impl = h.implementation { helper["implementation"] = .string(impl) }
            let enabled = (try? await backend.isLocalControlEnabled()) ?? false
            helper["local_control"] = .bool(enabled)
        }
        var r: [String: AnySendableJSON] = [
            "v": .int(LANLinkProtocol.version),
            "did": .string(identity.deviceID),
            "name": .string(identity.displayName),
            "capabilities": .object([
                "read_only": .bool(true),
                "subscribe": .bool(true),
                "tail": .bool(true),
            ]),
            "helper": .object(helper),
        ]
        if let cloud = identity.cloudDeviceID { r["cloud_device_id"] = .string(cloud) }
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
            await emitOutput(sub, sessionID: sid, text: payload, ts: ts)
        case let .sessionStarted(sid, provider, label):
            var d: [String: AnySendableJSON] = ["session_id": .string(sid), "provider": .string(provider)]
            if let label { d["client_label"] = .string(label) }
            await emit(sub, kind: .sessionStarted, data: d)
        case let .sessionStatus(sid, status):
            await emit(sub, kind: .sessionStatus, data: ["session_id": .string(sid), "status": .string(status)])
        case let .sessionStopped(sid, code):
            var d: [String: AnySendableJSON] = ["session_id": .string(sid)]
            if let code { d["exit_code"] = .int(code) }
            await flushOutput(sub)
            await emit(sub, kind: .sessionStopped, data: d)
        case .approvalRequested, .approvalResolved:
            // M1. Approvals are a control surface; a read-only client
            // does not get to see them.
            return
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
        ]
        if let l = row.clientLabel { d["client_label"] = .string(l) }
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
        default: return LANLinkProtocol.ErrorCode.internalError
        }
    }
}
