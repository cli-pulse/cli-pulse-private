import Foundation
import Network
import CryptoKit

/// What the Mac said in its `hello`, kept for the UI.
public struct LANHelloInfo: Equatable, Sendable {
    public let deviceID: String
    public let displayName: String
    public let cloudDeviceID: String?
    public let helperReachable: Bool
    public let helperImplementation: String?
    public let helperVersion: String?
    public let localControlEnabled: Bool
    public let readOnly: Bool
    // ── M1 ──
    /// This phone may control sessions on that Mac (attributed by the
    /// handshake, permitted by the Mac user). Same as `!readOnly`.
    public let controlAllowed: Bool
    /// The Mac user's home directory, for prefilling a working directory.
    public let home: String?
    /// Verbs the Mac advertises. An M0 Mac sends none; the read-only set
    /// is assumed then.
    public let methods: Set<String>
    /// Providers the helper can spawn.
    public let providerAvailability: [String]
    /// The helper's `claude_remote_control` hello field (stringified).
    public let claudeRemoteControl: [String: String]?

    public var claudeRemoteControlOfferable: Bool {
        guard let rc = claudeRemoteControl else { return false }
        return rc["supported"] == "true" && rc["policy"] != "disabled"
    }
}

/// The phone's end of the LAN link — a `SessionEventStreaming` conformer,
/// so the terminal screen and the session list are written once against
/// the same protocol the Mac app already uses for its own helper.
///
/// M1 adds control. Whether THIS link may control is what the Mac said in
/// `hello` (`capabilities.control`): a control call on a read-only link
/// throws `.notControllable` before touching the wire, and the agent
/// refuses it anyway (`control_not_allowed`), so the boundary holds even
/// if one side forgets. An M0 Mac answers M1 verbs with `not_implemented`
/// (or `bad_request` for a verb it never heard of) — both surface as
/// `.notImplemented` here.
///
/// Written against `LANLinkChannel`; `connect(to:peer:)` is the
/// convenience that opens the TLS-PSK connection, waits for `.ready`,
/// verifies the negotiated suite, and wraps it. Tests use the in-memory
/// channel and never touch a socket.
public final class LANSessionControlClient: SessionControlling, @unchecked Sendable {

    public enum ConnectError: Error, Equatable {
        case handshakeFailed(String)
        case unexpectedNegotiation(String)
        case timeout
    }

    private let channel: any LANLinkChannel
    private let heartbeatInterval: TimeInterval
    private let silenceTimeout: TimeInterval
    private let requestTimeout: TimeInterval
    private let lock = NSLock()

    private var pending: [String: CheckedContinuation<LANLinkFrame, Error>] = [:]
    private var subscriptions: [String: (AsyncThrowingStream<LocalSessionEvent, Error>.Continuation, UInt64)] = [:]
    private var lastInbound = Date()
    private var closed = false
    private var closeError: Error?
    private var pumpTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    /// Populated by the first successful `hello`.
    public private(set) var helloInfo: LANHelloInfo?

    /// Fires once, when the link ends. nil = clean close.
    public var onDisconnect: (@Sendable (Error?) -> Void)?

    /// (did, sessionKey) for the paired peer, used to prove which phone
    /// this is in `hello`. nil for a link with no binding (the in-memory
    /// test pair, or an M0-style read-only probe).
    private let binding: (did: String, sessionKey: SymmetricKey)?

    public init(
        channel: any LANLinkChannel,
        binding: (did: String, sessionKey: SymmetricKey)? = nil,
        heartbeatInterval: TimeInterval = LANLinkProtocol.heartbeatInterval,
        silenceTimeout: TimeInterval = LANLinkProtocol.peerSilenceTimeout,
        requestTimeout: TimeInterval = 5
    ) {
        self.channel = channel
        self.binding = binding
        self.heartbeatInterval = heartbeatInterval
        self.silenceTimeout = silenceTimeout
        self.requestTimeout = requestTimeout
        startPump()
        startHeartbeat()
    }

    deinit { close() }

    // MARK: - Connecting

    /// Open a TLS-PSK connection to a paired Mac. Throws if the handshake
    /// fails (wrong key, Mac gone) or negotiates anything other than the
    /// pinned suite.
    public static func connect(
        to endpoint: NWEndpoint,
        peer: LANPairing.PairedPeer,
        queue: DispatchQueue = DispatchQueue(label: "cli-pulse.lan.client"),
        timeout: TimeInterval = 5
    ) async throws -> LANSessionControlClient {
        let params = try LANTransportSecurity.parameters(presharedKeys: [peer.presharedKey])
        let conn = NWConnection(to: endpoint, using: params)
        try await Self.waitReady(conn, queue: queue, timeout: timeout)
        guard let n = LANTransportSecurity.negotiated(on: conn), n.isExpected else {
            conn.cancel()
            throw ConnectError.unexpectedNegotiation(
                "\(LANTransportSecurity.negotiated(on: conn).map { "0x\(String($0.ciphersuite, radix: 16))" } ?? "none")")
        }
        // M1: prove which paired phone this is to the Mac, so it can grant
        // control per phone. The proof is bound to THIS handshake's
        // exporter, so it cannot be replayed on another connection.
        return LANSessionControlClient(channel: NWConnectionChannel(connection: conn, queue: queue),
                                       binding: (did: peer.phoneDeviceID, sessionKey: peer.sessionKey))
    }

    /// Open a TLS-PSK connection with the PAIRING key, for
    /// `LANPairingSession.Client`.
    public static func connectForPairing(
        to endpoint: NWEndpoint,
        payload: LANPairing.QRPayload,
        queue: DispatchQueue = DispatchQueue(label: "cli-pulse.lan.pairing"),
        timeout: TimeInterval = 5
    ) async throws -> any LANLinkChannel {
        let params = try LANTransportSecurity.parameters(presharedKeys: [try LANPairing.pairingPSK(for: payload)])
        let conn = NWConnection(to: endpoint, using: params)
        try await Self.waitReady(conn, queue: queue, timeout: timeout)
        guard let n = LANTransportSecurity.negotiated(on: conn), n.isExpected else {
            conn.cancel()
            throw ConnectError.unexpectedNegotiation("pairing")
        }
        return NWConnectionChannel(connection: conn, queue: queue)
    }

    static func waitReady(_ conn: NWConnection, queue: DispatchQueue, timeout: TimeInterval) async throws {
        final class Once: @unchecked Sendable {
            let lock = NSLock(); var done = false
            func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let once = Once()
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    if once.first() { k.resume() }
                case .failed(let e):
                    if once.first() { k.resume(throwing: ConnectError.handshakeFailed("\(e)")) }
                case .waiting(let e):
                    // A PSK mismatch surfaces here as a handshake failure
                    // rather than `.failed`; do not sit in `.waiting`.
                    if once.first() { conn.cancel(); k.resume(throwing: ConnectError.handshakeFailed("\(e)")) }
                case .cancelled:
                    if once.first() { k.resume(throwing: ConnectError.handshakeFailed("cancelled")) }
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.first() { conn.cancel(); k.resume(throwing: ConnectError.timeout) }
            }
        }
    }

    // MARK: - SessionControlClient

    public func hello() async throws -> SessionControlHello {
        var p: [String: AnySendableJSON] = [:]
        if let binding, let exporter = channel.exporterSecret(label: LANPairing.peerBindingExporterLabel) {
            p["did"] = .string(binding.did)
            p["proof"] = .string(LANPairing.peerBindingProof(sessionKey: binding.sessionKey, exporter: exporter).base64EncodedString())
        }
        let r = try await request(.hello, p)
        guard let v = r["v"]?.intValue, v == LANLinkProtocol.version else {
            throw SessionControlError.versionMismatch
        }
        let helper = r["helper"]?.objectValue ?? [:]
        let caps = r["capabilities"]?.objectValue ?? [:]
        let control = caps["control"]?.boolValue ?? false
        let advertised = Set(r["methods"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        let methods = advertised.isEmpty ? Set(LANLinkProtocol.Method.readOnly.map(\.rawValue)) : advertised
        var rc: [String: String]? = nil
        if let o = helper["claude_remote_control"]?.objectValue {
            rc = o.compactMapValues { v in
                if let s = v.stringValue { return s }
                if let b = v.boolValue { return b ? "true" : "false" }
                return nil
            }
        }
        let info = LANHelloInfo(
            deviceID: r["did"]?.stringValue ?? "",
            displayName: r["name"]?.stringValue ?? "Mac",
            cloudDeviceID: r["cloud_device_id"]?.stringValue,
            helperReachable: helper["reachable"]?.boolValue ?? false,
            helperImplementation: helper["implementation"]?.stringValue,
            helperVersion: helper["version"]?.stringValue,
            localControlEnabled: helper["local_control"]?.boolValue ?? false,
            readOnly: !control,
            controlAllowed: control,
            home: r["home"]?.stringValue,
            methods: methods,
            providerAvailability: helper["provider_availability"]?.arrayValue?.compactMap(\.stringValue) ?? [],
            claudeRemoteControl: rc)
        lock.lock(); helloInfo = info; lock.unlock()
        return SessionControlHello(
            protocolVersion: v,
            supportedMethods: methods,
            capabilities: SessionControlCapabilities(
                sendInput: control,
                subscribeEvents: caps["subscribe"]?.boolValue ?? false,
                approvals: control),
            providerAvailability: info.providerAvailability,
            helperVersion: info.helperVersion ?? "",
            paired: info.helperReachable,
            providerPlanStatus: [:],
            implementation: info.helperImplementation,
            claudeRemoteControl: rc)
    }

    /// Before any control verb: what the last hello said. No hello yet ⇒
    /// let the wire answer (the agent refuses if it must).
    private func requireControl(_ m: LANLinkProtocol.Method) throws {
        lock.lock(); let info = helloInfo; lock.unlock()
        guard let info else { return }
        if info.readOnly { throw SessionControlError.notControllable }
        if !info.methods.contains(m.rawValue) { throw SessionControlError.notImplemented }
    }

    public func startManagedSession(provider: String, clientLabel: String?, cwdBasename: String?, cwdHmac: String?) async throws -> SessionControlStartResult {
        try await startManagedSession(provider: provider, clientLabel: clientLabel, cwd: nil, claudeRemoteControl: false)
    }

    public func startManagedSession(provider: String, clientLabel: String?, cwd: String?, claudeRemoteControl: Bool) async throws -> SessionControlStartResult {
        try requireControl(.sessionStart)
        var p: [String: AnySendableJSON] = ["provider": .string(provider)]
        if let clientLabel { p["client_label"] = .string(clientLabel) }
        if let cwd { p["cwd"] = .string(cwd) }
        if claudeRemoteControl { p["claude_remote_control"] = .bool(true) }
        let r = try await request(.sessionStart, p)
        guard let sid = r["session_id"]?.stringValue, !sid.isEmpty else {
            throw SessionControlError.invalidResponse("session.start reply missing session_id")
        }
        return SessionControlStartResult(sessionId: sid)
    }

    public func listSessions() async throws -> [SessionControlSummary] {
        let r = try await request(.sessionsList)
        return (r["sessions"]?.arrayValue ?? []).compactMap { row -> SessionControlSummary? in
            guard let o = row.objectValue, let id = o["id"]?.stringValue else { return nil }
            let rc = o["remote_control"]?.objectValue.flatMap { r in
                r["status"]?.stringValue.map { RemoteControlInfo(status: $0, url: r["url"]?.stringValue, reason: r["reason"]?.stringValue) }
            }
            return SessionControlSummary(
                id: id,
                provider: o["provider"]?.stringValue ?? "claude",
                clientLabel: o["client_label"]?.stringValue,
                status: o["status"]?.stringValue ?? "running",
                controllable: o["controllable"]?.boolValue ?? false,
                source: SessionControlSource(rawValue: o["source"]?.stringValue ?? "") ?? .managed,
                remoteControl: rc,
                attached: o["attached"]?.boolValue ?? false,
                localOnly: false)
        }
    }

    public func stopSession(sessionId: String) async throws {
        try requireControl(.sessionStop)
        _ = try await request(.sessionStop, ["session_id": .string(sessionId)])
    }

    /// The CR-append convenience: same bytes as the Mac's `send_input`
    /// (trailing newline becomes CR, otherwise CR appended).
    public func sendInput(sessionId: String, payload: String) async throws {
        var body = Data(payload.utf8)
        if body.last == 0x0a {
            body[body.count - 1] = 0x0d
            if body.count >= 2, body[body.count - 2] == 0x0d { body.removeLast() }
        } else if body.last != 0x0d {
            body.append(0x0d)
        }
        try await sendInputRaw(sessionId: sessionId, bytes: body)
    }

    // MARK: - SessionControlling (M1)

    /// Sent in frames of at most `maxInputBytesPerFrame`, in order. A
    /// paste from the phone is many frames; a keystroke is one.
    public func sendInputRaw(sessionId: String, bytes: Data) async throws {
        try requireControl(.sessionInput)
        var offset = 0
        repeat {
            let end = min(bytes.count, offset + LANLinkProtocol.maxInputBytesPerFrame)
            let chunk = bytes.subdata(in: offset..<end)
            _ = try await request(.sessionInput, ["session_id": .string(sessionId),
                                                  "bytes_b64": .string(chunk.base64EncodedString())])
            offset = end
        } while offset < bytes.count
    }

    public func resize(sessionId: String, cols: Int, rows: Int) async throws {
        guard (1...1000).contains(cols), (1...1000).contains(rows) else {
            throw SessionControlError.invalidResponse("resize: cols/rows must be 1…1000 (got \(cols)×\(rows))")
        }
        try requireControl(.sessionResize)
        _ = try await request(.sessionResize, ["session_id": .string(sessionId), "cols": .int(cols), "rows": .int(rows)])
    }

    public func getPendingApprovals(sessionId: String?) async throws -> [PendingApproval] {
        try requireControl(.approvalsList)
        var p: [String: AnySendableJSON] = [:]
        if let sessionId { p["session_id"] = .string(sessionId) }
        let r = try await request(.approvalsList, p)
        return (r["approvals"]?.arrayValue ?? []).compactMap { row in
            row.objectValue.flatMap { PendingApproval.decode(from: $0.mapValues { $0.foundationValue }) }
        }
    }

    public func approveAction(sessionId: String, approvalId: String, decision: ApprovalDecision, comment: String?) async throws {
        try requireControl(.approvalDecide)
        var p: [String: AnySendableJSON] = [
            "session_id": .string(sessionId), "approval_id": .string(approvalId), "decision": .string(decision.rawValue),
        ]
        if let comment, !comment.isEmpty { p["comment"] = .string(comment) }
        _ = try await request(.approvalDecide, p)
    }

    // MARK: - SessionEventStreaming

    public func getTailSnapshot(sessionId: String, maxBytes: Int) async throws -> Data {
        let r = try await request(.sessionTail, ["session_id": .string(sessionId), "max_bytes": .int(maxBytes)])
        guard let b64 = r["bytes_b64"]?.stringValue, let data = Data(base64Encoded: b64) else {
            throw SessionControlError.invalidResponse("tail reply missing bytes")
        }
        return data
    }

    public func isLocalControlEnabled() async throws -> Bool {
        _ = try await hello()
        lock.lock(); let v = helloInfo?.localControlEnabled ?? false; lock.unlock()
        return v
    }

    /// Tracks a subscription from the moment the stream exists, so a
    /// consumer that goes away while `session.subscribe` is still in
    /// flight releases the agent-side subscription once the reply lands
    /// — otherwise a few dismissed screens exhaust the per-connection cap.
    private final class SubscribeState: @unchecked Sendable {
        private let lock = NSLock()
        private var terminated = false
        private var sub: String?
        /// Returns the sub to release NOW if the consumer already left.
        func attach(_ s: String) -> String? { lock.lock(); defer { lock.unlock() }; sub = s; return terminated ? s : nil }
        /// Returns the sub to release NOW if the reply already landed.
        func terminate() -> String? { lock.lock(); defer { lock.unlock() }; terminated = true; return sub }
    }

    public func subscribeEvents(sessionId: String?) -> AsyncThrowingStream<LocalSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let state = SubscribeState()
            continuation.onTermination = { [weak self] _ in
                guard let self, let sub = state.terminate() else { return }
                self.lock.lock(); self.subscriptions[sub] = nil; self.lock.unlock()
                Task { _ = try? await self.request(.sessionUnsubscribe, ["sub": .string(sub)]) }
            }
            let task = Task { [self] in
                do {
                    var p: [String: AnySendableJSON] = [:]
                    if let sessionId { p["session_id"] = .string(sessionId) }
                    let r = try await request(.sessionSubscribe, p)
                    guard let sub = r["sub"]?.stringValue else {
                        throw SessionControlError.invalidResponse("subscribe reply missing sub")
                    }
                    if let orphan = state.attach(sub) {
                        _ = try? await request(.sessionUnsubscribe, ["sub": .string(orphan)])
                        return
                    }
                    lock.lock(); subscriptions[sub] = (continuation, 0); lock.unlock()
                    continuation.yield(.subscribed(sessionId: sessionId, managedSessions: [], pendingApprovals: []))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            _ = task
        }
    }

    // MARK: - Request/reply

    private func request(_ m: LANLinkProtocol.Method, _ p: [String: AnySendableJSON] = [:]) async throws -> [String: AnySendableJSON] {
        lock.lock()
        if closed { let e = closeError; lock.unlock(); throw e ?? SessionControlError.disconnected }
        lock.unlock()

        let id = UUID().uuidString
        let frame: LANLinkFrame = try await withThrowingTaskGroup(of: LANLinkFrame.self) { group in
            group.addTask { [self] in
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<LANLinkFrame, Error>) in
                    lock.lock(); pending[id] = k; lock.unlock()
                    Task {
                        do {
                            try await channel.send(try LANLinkFrame.request(id: id, method: m.rawValue, params: p).encode())
                        } catch {
                            lock.lock(); let k2 = pending.removeValue(forKey: id); lock.unlock()
                            k2?.resume(throwing: SessionControlError.disconnected)
                        }
                    }
                }
            }
            group.addTask { [self] in
                try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                lock.lock(); let k = pending.removeValue(forKey: id); lock.unlock()
                k?.resume(throwing: SessionControlError.timeout)
                throw SessionControlError.timeout
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        guard case let .reply(_, ok, r, e) = frame else { throw SessionControlError.invalidResponse("not a reply") }
        if ok { return r }
        guard let e else { throw SessionControlError.internalError("unknown") }
        // An M0 Mac: control verbs answer `not_implemented`; a verb it
        // never heard of answers `bad_request` "unknown method". Either
        // way: this Mac cannot do M1.
        if m.isM1, e.code == LANLinkProtocol.ErrorCode.notImplemented
            || (e.code == LANLinkProtocol.ErrorCode.badRequest && e.message.hasPrefix("unknown method")) {
            throw SessionControlError.notImplemented
        }
        throw e.asSessionControlError
    }

    // MARK: - Inbound pump

    private func startPump() {
        pumpTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await body in channel.inbound {
                    lock.lock(); lastInbound = Date(); lock.unlock()
                    guard let f = try? LANLinkFrame.decode(body) else { continue }
                    dispatch(f)
                }
                finish(nil)
            } catch {
                finish(error)
            }
        }
    }

    private func dispatch(_ f: LANLinkFrame) {
        switch f {
        case .heartbeat:
            return
        case let .reply(id, _, _, _):
            lock.lock(); let k = pending.removeValue(forKey: id); lock.unlock()
            k?.resume(returning: f)
        case let .event(kind, sub, seq, d):
            lock.lock()
            guard let (cont, last) = subscriptions[sub] else { lock.unlock(); return }
            if seq != last + 1 {
                // Frames were lost. Say so rather than paint a hole.
                cont.yield(.other(name: "seq_gap", raw: ["expected": last + 1, "got": seq]))
            }
            subscriptions[sub] = (cont, seq)
            lock.unlock()
            forward(kind: kind, data: d, to: cont, sub: sub)
        case .request:
            // The agent never sends requests. Ignore rather than close —
            // a future agent might, and a read-only client has nothing to
            // lose by ignoring.
            return
        }
    }

    private func forward(kind: String, data d: [String: AnySendableJSON],
                         to cont: AsyncThrowingStream<LocalSessionEvent, Error>.Continuation, sub: String) {
        let sid = d["session_id"]?.stringValue ?? ""
        switch LANLinkProtocol.EventKind(rawValue: kind) {
        case .output:
            guard let b64 = d["bytes_b64"]?.stringValue, let bytes = Data(base64Encoded: b64) else { return }
            let ts = d["ts"]?.intValue.map(Double.init) ?? Date().timeIntervalSince1970
            // `.outputRaw`: ANSI is preserved on this path, which is what
            // the xterm.js host wants.
            cont.yield(.outputRaw(sessionId: sid, payload: String(decoding: bytes, as: UTF8.self), ts: ts))
        case .sessionStarted:
            cont.yield(.sessionStarted(sessionId: sid, provider: d["provider"]?.stringValue ?? "claude",
                                       clientLabel: d["client_label"]?.stringValue))
        case .sessionStatus:
            cont.yield(.sessionStatus(sessionId: sid, status: d["status"]?.stringValue ?? ""))
        case .sessionStopped:
            cont.yield(.sessionStopped(sessionId: sid, exitCode: d["exit_code"]?.intValue))
        case .approvalRequested:
            guard let raw = d["approval"]?.objectValue,
                  let a = PendingApproval.decode(from: raw.mapValues { $0.foundationValue }) else { return }
            cont.yield(.approvalRequested(approval: a))
        case .approvalResolved:
            cont.yield(.approvalResolved(sessionId: sid, approvalId: d["approval_id"]?.stringValue ?? "",
                                         decision: d["decision"]?.stringValue ?? "", status: d["status"]?.stringValue ?? ""))
        case .sessionRemoteControl:
            cont.yield(.sessionRemoteControl(sessionId: sid, status: d["status"]?.stringValue ?? "",
                                             url: d["url"]?.stringValue, reason: d["reason"]?.stringValue))
        case .subscriptionEnded:
            lock.lock(); subscriptions[sub] = nil; lock.unlock()
            switch LANLinkProtocol.SubscriptionEndReason(rawValue: d["reason"]?.stringValue ?? "") {
            case .localControlDisabled: cont.finish(throwing: SessionControlError.localControlOff)
            case .helperGone: cont.finish(throwing: SessionControlError.helperNotRunning)
            default: cont.finish()
            }
        case .none:
            cont.yield(.other(name: kind, raw: d.mapValues { $0.value }))
        }
    }

    // MARK: - Heartbeat / liveness

    private func startHeartbeat() {
        heartbeatTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { return }
                self.lock.lock(); let silent = Date().timeIntervalSince(self.lastInbound) > self.silenceTimeout; self.lock.unlock()
                if silent {
                    self.finish(SessionControlError.timeout)
                    return
                }
                try? await self.channel.send(try LANLinkFrame.heartbeat(ts: Date().timeIntervalSince1970).encode())
            }
        }
    }

    // MARK: - Teardown

    public func close() {
        finish(nil)
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        closeError = error ?? SessionControlError.disconnected
        let ps = pending; pending = [:]
        let subs = subscriptions; subscriptions = [:]
        let cb = onDisconnect
        lock.unlock()
        heartbeatTask?.cancel()
        pumpTask?.cancel()
        channel.close()
        for (_, k) in ps { k.resume(throwing: error ?? SessionControlError.disconnected) }
        for (_, (c, _)) in subs {
            if let error { c.finish(throwing: error) } else { c.finish(throwing: SessionControlError.disconnected) }
        }
        cb?(error)
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }
}
