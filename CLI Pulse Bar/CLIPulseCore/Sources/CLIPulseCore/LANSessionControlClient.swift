import Foundation
import Network

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
}

/// The phone's end of the LAN link — a `SessionEventStreaming` conformer,
/// so the terminal screen and the session list are written once against
/// the same protocol the Mac app already uses for its own helper.
///
/// M0 is read-only: `startManagedSession`, `stopSession` and `sendInput`
/// throw `.notImplemented` here AND are refused by the agent, so the
/// boundary holds even if one side forgets.
///
/// Written against `LANLinkChannel`; `connect(to:peer:)` is the
/// convenience that opens the TLS-PSK connection, waits for `.ready`,
/// verifies the negotiated suite, and wraps it. Tests use the in-memory
/// channel and never touch a socket.
public final class LANSessionControlClient: SessionEventStreaming, @unchecked Sendable {

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

    public init(
        channel: any LANLinkChannel,
        heartbeatInterval: TimeInterval = LANLinkProtocol.heartbeatInterval,
        silenceTimeout: TimeInterval = LANLinkProtocol.peerSilenceTimeout,
        requestTimeout: TimeInterval = 5
    ) {
        self.channel = channel
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
        return LANSessionControlClient(channel: NWConnectionChannel(connection: conn, queue: queue))
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
        let r = try await request(.hello)
        guard let v = r["v"]?.intValue, v == LANLinkProtocol.version else {
            throw SessionControlError.versionMismatch
        }
        let helper = r["helper"]?.objectValue ?? [:]
        let caps = r["capabilities"]?.objectValue ?? [:]
        let info = LANHelloInfo(
            deviceID: r["did"]?.stringValue ?? "",
            displayName: r["name"]?.stringValue ?? "Mac",
            cloudDeviceID: r["cloud_device_id"]?.stringValue,
            helperReachable: helper["reachable"]?.boolValue ?? false,
            helperImplementation: helper["implementation"]?.stringValue,
            helperVersion: helper["version"]?.stringValue,
            localControlEnabled: helper["local_control"]?.boolValue ?? false,
            readOnly: caps["read_only"]?.boolValue ?? true)
        lock.lock(); helloInfo = info; lock.unlock()
        return SessionControlHello(
            protocolVersion: v,
            supportedMethods: Set(LANLinkProtocol.Method.readOnly.map(\.rawValue)),
            capabilities: SessionControlCapabilities(
                sendInput: false,
                subscribeEvents: caps["subscribe"]?.boolValue ?? false,
                approvals: false),
            providerAvailability: [],
            helperVersion: info.helperVersion ?? "",
            paired: info.helperReachable,
            providerPlanStatus: [:],
            implementation: info.helperImplementation)
    }

    public func startManagedSession(provider: String, clientLabel: String?, cwdBasename: String?, cwdHmac: String?) async throws -> SessionControlStartResult {
        throw SessionControlError.notImplemented
    }

    public func listSessions() async throws -> [SessionControlSummary] {
        let r = try await request(.sessionsList)
        return (r["sessions"]?.arrayValue ?? []).compactMap { row -> SessionControlSummary? in
            guard let o = row.objectValue, let id = o["id"]?.stringValue else { return nil }
            return SessionControlSummary(
                id: id,
                provider: o["provider"]?.stringValue ?? "claude",
                clientLabel: o["client_label"]?.stringValue,
                status: o["status"]?.stringValue ?? "running",
                controllable: o["controllable"]?.boolValue ?? false,
                source: SessionControlSource(rawValue: o["source"]?.stringValue ?? "") ?? .managed)
        }
    }

    public func stopSession(sessionId: String) async throws {
        throw SessionControlError.notImplemented
    }

    public func sendInput(sessionId: String, payload: String) async throws {
        throw SessionControlError.notImplemented
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

    public func subscribeEvents(sessionId: String?) -> AsyncThrowingStream<LocalSessionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    var p: [String: AnySendableJSON] = [:]
                    if let sessionId { p["session_id"] = .string(sessionId) }
                    let r = try await request(.sessionSubscribe, p)
                    guard let sub = r["sub"]?.stringValue else {
                        throw SessionControlError.invalidResponse("subscribe reply missing sub")
                    }
                    lock.lock(); subscriptions[sub] = (continuation, 0); lock.unlock()
                    continuation.yield(.subscribed(sessionId: sessionId, managedSessions: [], pendingApprovals: []))
                    continuation.onTermination = { [weak self] _ in
                        guard let self else { return }
                        self.lock.lock(); self.subscriptions[sub] = nil; self.lock.unlock()
                        Task { _ = try? await self.request(.sessionUnsubscribe, ["sub": .string(sub)]) }
                    }
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
        throw e?.asSessionControlError ?? SessionControlError.internalError("unknown")
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
