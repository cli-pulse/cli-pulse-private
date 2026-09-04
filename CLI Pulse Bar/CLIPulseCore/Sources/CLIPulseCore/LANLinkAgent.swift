#if os(macOS)
import Foundation
import Network
import Combine
import os

private let agentLog = Logger(subsystem: "com.cli-pulse.bar", category: "lan-agent")

/// The Mac-side remote-control agent: listeners, Bonjour, pairing, and
/// the per-connection sessions. Lives in the APP process — it is the
/// holder of the helper auth token, which never crosses the network.
///
/// ── Two listeners, on purpose ──
///
/// The STEADY listener's key set is exactly the paired phones, and the
/// PAIRING listener's key set is exactly the current QR's key, so a phone
/// that only holds a QR nonce reaches a listener that cannot serve
/// sessions, whatever it claims to be. Since M1 each connection also
/// proves WHICH phone it is: in `hello` the phone sends its `did` and an
/// HMAC over the connection's exporter keyed by the shared per-peer key
/// (`LANPairing.peerBindingProof`), which the agent verifies against the
/// stored key for that `did`. Portable (documented CryptoKit + exporter,
/// no version-specific TLS introspection) and it is what per-phone
/// control permission and "Forget closes the live link" rest on.
///
/// The steady listener is recreated whenever the peer set changes —
/// `NWParameters` are fixed at start.
///
/// ── Where it is unavailable, and why it says so ──
///
/// Session control on this Mac requires the unsandboxed LaunchAgent
/// helper, which the Mac App Store build cannot register (the same
/// `MASSandboxGate` predicate hides the in-app terminal there). A
/// listener in that build would bind a port and serve an empty session
/// list. Rather than that, `state` is `.unavailable` with a reason the
/// Settings UI can show, and nothing binds.
///
/// The bind is also OBSERVED, not assumed: `state` records what
/// `NWListener` actually reported, so an entitlement or sandbox surprise
/// shows up as `.failed(...)` with the OS's own error rather than as a
/// phone that silently never connects.
@MainActor
public final class LANLinkAgent: ObservableObject {

    public enum State: Equatable, Sendable {
        case off
        case unavailable(reason: String)
        case starting
        case listening(port: UInt16, peerCount: Int, connections: Int)
        case failed(String)
    }

    public enum PairingState: Equatable, Sendable {
        case idle
        case showingQR(url: String, expiresAt: Date)
        case awaitingApproval(sas: String, peerName: String)
        case succeeded(peerName: String)
        case failed(String)
    }

    @Published public private(set) var state: State = .off
    @Published public private(set) var pairing: PairingState = .idle
    @Published public private(set) var peers: [LANPairing.PairedPeer] = []

    /// User-facing toggle, persisted. Off by default: a listener nobody
    /// asked for is the notification-permission mistake in another form.
    public static let enabledDefaultsKey = "cli_pulse_lan_remote_enabled"

    public var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledDefaultsKey)
            objectWillChange.send()
            if newValue { start() } else { stop() }
        }
    }

    public private(set) var identity: LANPairing.LocalIdentity?

    private let backend: any SessionControlling
    private let displayName: String
    private let cloudDeviceID: @Sendable () -> String?
    private let queue = DispatchQueue(label: "cli-pulse.lan.agent")

    private var steadyListener: NWListener?
    private var pairingListener: NWListener?
    private var sessions: [ObjectIdentifier: (session: LANLinkAgentSession, task: Task<Void, Never>, peerID: Box)] = [:]
    /// A mutable holder so the session's own hello handler can report the
    /// peer it proved back to the agent (for Forget-closes-links).
    final class Box: @unchecked Sendable { var id: String?; init() {} }
    private var pairingTask: Task<Void, Never>?
    private var pairingDecision: CheckedContinuation<Bool, Never>?
    private var pairingExpiryTask: Task<Void, Never>?
    private var currentQR: LANPairing.QRPayload?

    public init(
        backend: any SessionControlling,
        displayName: String = Host.current().localizedName ?? "Mac",
        cloudDeviceID: @escaping @Sendable () -> String? = { nil }
    ) {
        self.backend = backend
        self.displayName = displayName
        self.cloudDeviceID = cloudDeviceID
    }

    // MARK: - Availability

    /// Why the agent cannot run on this build, or nil if it can.
    public static var unavailabilityReason: String? {
        if MASSandboxGate.isSandboxed {
            return "Remote control needs the Developer ID build of CLI Pulse — session control is not available in the App Store build."
        }
        return nil
    }

    // MARK: - Lifecycle

    public func start() {
        guard steadyListener == nil else { return }
        if let reason = Self.unavailabilityReason {
            state = .unavailable(reason: reason)
            return
        }
        do {
            identity = try LANPairingStore.loadOrCreateIdentity()
        } catch {
            state = .failed("Could not create a device identity: \(error)")
            return
        }
        peers = LANPairingStore.peers()
        state = .starting
        restartSteadyListener()
    }

    public func stop() {
        cancelPairing()
        steadyListener?.cancel()
        steadyListener = nil
        for (_, entry) in sessions {
            let s = entry.session
            Task { await s.close() }
            entry.task.cancel()
        }
        sessions = [:]
        state = .off
    }

    public func forget(peerID: String) {
        LANPairingStore.remove(peerID: peerID)
        peers = LANPairingStore.peers()
        // Cancelling the listener does NOT close accepted connections
        // (measured: they stay `.ready` with data flowing). Close this
        // phone's live links explicitly — AND every still-unattributed
        // connection (one that never sent a valid hello binding proof, so
        // `box.id` is nil). A forgotten phone that only ever watched
        // read-only never proved a peer id, so matching on the id alone
        // would leave its covert stream running past Forget. An innocent
        // phone caught mid-handshake just reconnects.
        closeSessions { $0 == peerID || $0 == nil }
        if steadyListener != nil { restartSteadyListener() }
    }

    public func forgetAll() {
        LANPairingStore.removeAllPeers()
        peers = []
        closeSessions { _ in true }
        if steadyListener != nil { restartSteadyListener() }
    }

    /// M1: allow or withdraw CONTROL for one phone without cutting its
    /// link. Live connections ask on every control frame, so this applies
    /// to the very next keystroke.
    public func setControlAllowed(peerID: String, _ allowed: Bool) {
        do {
            try LANPairingStore.setControlAllowed(peerID: peerID, allowed)
        } catch {
            agentLog.error("setControlAllowed(\(peerID, privacy: .public)) failed: \(String(describing: error))")
        }
        peers = LANPairingStore.peers()
    }

    private func closeSessions(where match: (String?) -> Bool) {
        for (_, entry) in sessions where match(entry.peerID.id) {
            let s = entry.session
            Task { await s.close() }
        }
    }

    // MARK: - Steady listener

    private func restartSteadyListener() {
        steadyListener?.cancel()
        steadyListener = nil
        guard let identity else { return }

        let listener: NWListener
        do {
            let params = try LANTransportSecurity.parameters(presharedKeys: peers.map(\.presharedKey))
            listener = try NWListener(using: params)
        } catch {
            state = .failed("Listener setup failed: \(error)")
            return
        }
        let txt = NWTXTRecord([
            LANLinkProtocol.TXTKey.deviceID: identity.deviceID,
            LANLinkProtocol.TXTKey.protocolVersion: String(LANLinkProtocol.version),
        ])
        listener.service = NWListener.Service(name: displayName,
                                              type: LANLinkProtocol.bonjourServiceType,
                                              txtRecord: txt)
        listener.stateUpdateHandler = { [weak self] st in
            Task { @MainActor [weak self] in
                guard let self, self.steadyListener === listener else { return }
                switch st {
                case .ready:
                    self.state = .listening(port: listener.port?.rawValue ?? 0,
                                            peerCount: self.peers.count,
                                            connections: self.sessions.count)
                case .failed(let e):
                    agentLog.error("steady listener failed: \(String(describing: e))")
                    self.state = .failed("\(e)")
                case .cancelled:
                    if case .listening = self.state { self.state = .off }
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.accept(conn) }
        }
        steadyListener = listener
        listener.start(queue: queue)
    }

    private func accept(_ conn: NWConnection) {
        let queue = self.queue
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                guard let n = LANTransportSecurity.negotiated(on: conn), n.isExpected else {
                    agentLog.error("refusing connection: unexpected TLS negotiation")
                    conn.cancel()
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    // Which phone is proven in `hello`, not here.
                    self.startSession(over: NWConnectionChannel(connection: conn, queue: queue))
                }
            case .failed(let e):
                agentLog.notice("inbound connection failed before ready: \(String(describing: e))")
            default: break
            }
        }
        conn.start(queue: queue)
    }

    private func startSession(over channel: any LANLinkChannel) {
        guard let identity else { channel.close(); return }
        // Filled in when the session proves a peer in hello; read by
        // `closeSessions` so Forget can drop a specific phone's links.
        let box = Box()
        let session = LANLinkAgentSession(
            channel: channel, backend: backend,
            identity: LANAgentIdentity(deviceID: identity.deviceID,
                                       displayName: displayName,
                                       cloudDeviceID: cloudDeviceID(),
                                       home: UnsandboxedDataMigration.realUserHome().path),
            // Verify the phone's binding proof against the stored key for
            // the did it claims. Runs on the agent's actor; hops to the
            // main actor to read the live peer list.
            authenticatePeer: { [weak self] did, proof, exporter in
                guard let self else { return nil }
                let match: LANAgentPeer? = await MainActor.run {
                    guard let stored = self.peers.first(where: { $0.id == did }),
                          LANPairing.verifyPeerBinding(sessionKey: stored.sessionKey, exporter: exporter, proof: proof)
                    else { return nil }
                    box.id = stored.id
                    return LANAgentPeer(id: stored.id, displayName: stored.displayName, controlAllowed: stored.controlAllowed)
                }
                return match
            },
            // The live permission: the stored record, re-read on every
            // control frame so the Settings toggle applies immediately.
            controlPermitted: { [weak self] in
                await MainActor.run {
                    guard let self, let id = box.id else { return false }
                    return self.peers.first(where: { $0.id == id })?.controlAllowed ?? false
                }
            })
        let key = ObjectIdentifier(session)
        let task = Task { [weak self] in
            let reason = await session.run()
            agentLog.notice("session ended: \(String(describing: reason))")
            await MainActor.run { self?.sessionEnded(key) }
        }
        sessions[key] = (session, task, box)
        refreshListeningState()
    }

    private func sessionEnded(_ key: ObjectIdentifier) {
        sessions[key] = nil
        refreshListeningState()
    }

    private func refreshListeningState() {
        if case .listening = state {
            state = .listening(port: steadyListener?.port?.rawValue ?? 0,
                               peerCount: peers.count, connections: sessions.count)
        }
    }

    // MARK: - Pairing

    /// Mint a QR and open the pairing listener for 60 s.
    public func beginPairing() {
        guard let identity, steadyListener != nil else {
            pairing = .failed("Turn remote control on first")
            return
        }
        cancelPairing()
        let payload = LANPairing.QRPayload.mint(deviceID: identity.deviceID)
        currentQR = payload

        let listener: NWListener
        do {
            listener = try NWListener(using: try LANTransportSecurity.parameters(
                presharedKeys: [try LANPairing.pairingPSK(for: payload)]))
        } catch {
            pairing = .failed("\(error)")
            return
        }
        // A distinct name: two services with the same name and type make
        // Bonjour rename the second one "(2)", which is what the phone would
        // show. The phone matches pairing services by TXT `did` + `m`, never
        // by name, so the suffix is purely for humans and dns-sd transcripts.
        listener.service = NWListener.Service(
            name: displayName + " (pairing)",
            type: LANLinkProtocol.bonjourServiceType,
            txtRecord: NWTXTRecord([
                LANLinkProtocol.TXTKey.deviceID: identity.deviceID,
                LANLinkProtocol.TXTKey.protocolVersion: String(LANLinkProtocol.version),
                LANLinkProtocol.TXTKey.mode: LANLinkProtocol.TXTMode.pairing,
            ]))
        listener.stateUpdateHandler = { [weak self] st in
            if case .failed(let e) = st {
                Task { @MainActor [weak self] in self?.pairing = .failed("\(e)") }
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            Task { @MainActor [weak self] in self?.acceptPairing(conn, payload: payload) }
        }
        pairingListener = listener
        listener.start(queue: queue)
        pairing = .showingQR(url: payload.urlString, expiresAt: payload.expiresAt)

        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LANPairing.qrLifetime * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                switch self.pairing {
                case .showingQR:
                    // Nobody connected. Tear it all down here.
                    self.cancelPairing()
                    self.pairing = .failed("QR code expired")
                case .awaitingApproval:
                    // Someone connected and the user never answered. The
                    // session is parked on `askUser`; answer "no" for it,
                    // and let the session finish through `pairingFinished`
                    // (which sees the expired payload, reports `.expired`,
                    // and cancels the listener). Found on hardware: without
                    // this arm the pairing listener stayed up for good.
                    self.rejectPairing()
                default:
                    break
                }
            }
        }
    }

    private func acceptPairing(_ conn: NWConnection, payload: LANPairing.QRPayload) {
        // One pairing at a time: a second connection during a pairing is
        // exactly the "second phone scanned the same QR" case. Refuse.
        guard pairingTask == nil, let identity, currentQR == payload else {
            conn.cancel()
            return
        }
        let queue = self.queue
        conn.stateUpdateHandler = { [weak self] st in
            guard case .ready = st else { return }
            guard let n = LANTransportSecurity.negotiated(on: conn), n.isExpected else {
                conn.cancel(); return
            }
            Task { @MainActor [weak self] in
                guard let self, self.pairingTask == nil else { conn.cancel(); return }
                let channel = NWConnectionChannel(connection: conn, queue: queue)
                let agent = LANPairingSession.Agent(
                    channel: channel, identity: identity, displayName: self.displayName, payload: payload,
                    decide: { [weak self] sas, name in
                        await self?.askUser(sas: sas, peerName: name) ?? false
                    })
                self.pairingTask = Task { [weak self] in
                    let outcome = await agent.run()
                    await MainActor.run { [weak self] in self?.pairingFinished(outcome) }
                }
            }
        }
        conn.start(queue: queue)
    }

    private func askUser(sas: String, peerName: String) async -> Bool {
        pairing = .awaitingApproval(sas: sas, peerName: peerName)
        return await withCheckedContinuation { k in
            pairingDecision = k
        }
    }

    /// The user compared the codes and tapped Approve.
    public func approvePairing() {
        pairingDecision?.resume(returning: true)
        pairingDecision = nil
    }

    public func rejectPairing() {
        pairingDecision?.resume(returning: false)
        pairingDecision = nil
    }

    public func cancelPairing() {
        pairingDecision?.resume(returning: false)
        pairingDecision = nil
        pairingTask?.cancel()
        pairingTask = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingListener?.cancel()
        pairingListener = nil
        currentQR = nil
        if case .showingQR = pairing { pairing = .idle }
        if case .awaitingApproval = pairing { pairing = .idle }
    }

    private func pairingFinished(_ outcome: LANPairingSession.Agent.Outcome) {
        pairingTask = nil
        pairingListener?.cancel()
        pairingListener = nil
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        currentQR = nil   // the nonce is consumed either way
        switch outcome {
        case .paired(let peer):
            do {
                try LANPairingStore.save(peer)
                peers = LANPairingStore.peers()
                pairing = .succeeded(peerName: peer.displayName)
                restartSteadyListener()
            } catch {
                pairing = .failed("Could not save the pairing: \(error)")
            }
        case .rejected: pairing = .failed("Declined")
        case .expired: pairing = .failed("QR code expired")
        case .failed(let why): pairing = .failed(why)
        }
    }

    public func dismissPairingResult() {
        switch pairing {
        case .succeeded, .failed: pairing = .idle
        default: break
        }
    }
}
#endif
