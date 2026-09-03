import Foundation
import Network

/// A bidirectional stream of frame BODIES. The one seam between "what the
/// agent and the phone say to each other" and "how the bytes travel".
///
/// The agent session and the phone client are written against this, not
/// against `NWConnection`, for two reasons that are the same reason:
/// tests drive both ends over an in-memory pair with no socket, and M2's
/// relay is a second conformer that carries the same frames through an
/// E2E-encrypted WebSocket. If either of those needed the session layer
/// to change, the seam would be in the wrong place.
public protocol LANLinkChannel: AnyObject, Sendable {
    /// Frame bodies as they arrive, already split by the length prefix.
    /// Finishes when the peer closes cleanly; throws on a transport
    /// error. Consumed exactly once.
    var inbound: AsyncThrowingStream<Data, Error> { get }

    /// Send one frame body (the framer adds the length prefix).
    func send(_ body: Data) async throws

    /// Tear down. Idempotent. Makes `inbound` finish.
    func close()

    /// RFC 5705 exporter for this connection's handshake, or nil when
    /// the channel has no TLS (the in-memory test pair). Pairing derives
    /// its short authentication string from this.
    func exporterSecret(label: String) -> Data?

    /// What TLS negotiated, or nil for a non-TLS channel.
    var negotiated: LANTransportSecurity.Negotiated? { get }
}

public enum LANLinkChannelError: Error, Equatable {
    case closed
    case sendFailed(String)
    case receiveFailed(String)
    case framing(LANLinkFramer.FrameError)
}

// MARK: - Network.framework adapter

/// `LANLinkChannel` over an ESTABLISHED `NWConnection` — the caller has
/// already seen `.ready` and (for TLS) checked `negotiated.isExpected`.
///
/// Receive discipline: exactly ONE outstanding `receive` at a time. With
/// two, the older callback eats the next frame's bytes before the newer
/// one sees them; the codebase learnt that on PR #18 and this adapter
/// inherits the rule rather than rediscovering it.
public final class NWConnectionChannel: LANLinkChannel, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var continuation: AsyncThrowingStream<Data, Error>.Continuation?
    public let inbound: AsyncThrowingStream<Data, Error>

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.inbound = AsyncThrowingStream { cont = $0 }
        self.continuation = cont
        cont.onTermination = { [weak self] _ in self?.close() }
        connection.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed(let e): self?.finish(throwing: LANLinkChannelError.receiveFailed("\(e)"))
            case .cancelled: self?.finish(throwing: nil)
            default: break
            }
        }
        receiveLoop(framer: LANLinkFramer())
    }

    private func receiveLoop(framer: LANLinkFramer) {
        var framer = framer
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(throwing: LANLinkChannelError.receiveFailed("\(error)"))
                return
            }
            if let data, !data.isEmpty {
                do {
                    for body in try framer.append(data) {
                        self.lock.lock(); let c = self.continuation; self.lock.unlock()
                        c?.yield(body)
                    }
                } catch let e as LANLinkFramer.FrameError {
                    // Oversized header: the peer is misbehaving. Close.
                    self.finish(throwing: LANLinkChannelError.framing(e))
                    return
                } catch {
                    self.finish(throwing: LANLinkChannelError.receiveFailed("\(error)"))
                    return
                }
            }
            if isComplete {
                self.finish(throwing: nil)
                return
            }
            self.receiveLoop(framer: framer)
        }
    }

    private func finish(throwing error: Error?) {
        lock.lock()
        let c = continuation
        continuation = nil
        let wasClosed = closed
        closed = true
        lock.unlock()
        if let error { c?.finish(throwing: error) } else { c?.finish() }
        if !wasClosed { connection.cancel() }
    }

    public func send(_ body: Data) async throws {
        lock.lock(); let isClosed = closed; lock.unlock()
        if isClosed { throw LANLinkChannelError.closed }
        let framed = try LANLinkFramer.frame(body)
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { k.resume(throwing: LANLinkChannelError.sendFailed("\(error)")) }
                else { k.resume() }
            })
        }
    }

    public func close() {
        finish(throwing: nil)
    }

    public func exporterSecret(label: String) -> Data? {
        LANTransportSecurity.exporterSecret(on: connection, label: label)
    }

    public var negotiated: LANTransportSecurity.Negotiated? {
        LANTransportSecurity.negotiated(on: connection)
    }
}

// MARK: - In-memory pair (tests, and any future in-process transport)

/// Two channels wired back to back. What one sends, the other receives.
/// No framing, no TLS; `exporterSecret` returns a fixed per-pair value so
/// pairing logic can be exercised deterministically.
public final class InMemoryLANLinkChannel: LANLinkChannel, @unchecked Sendable {
    public let inbound: AsyncThrowingStream<Data, Error>
    private let inboundContinuation: AsyncThrowingStream<Data, Error>.Continuation
    private weak var peer: InMemoryLANLinkChannel?
    private let lock = NSLock()
    private var closed = false
    private let exporter: Data

    /// Frames this end has SENT, for assertions.
    public private(set) var sent: [Data] = []

    private init(exporter: Data) {
        var cont: AsyncThrowingStream<Data, Error>.Continuation!
        self.inbound = AsyncThrowingStream { cont = $0 }
        self.inboundContinuation = cont
        self.exporter = exporter
    }

    public static func pair(exporter: Data = Data(repeating: 0xAB, count: 32))
        -> (a: InMemoryLANLinkChannel, b: InMemoryLANLinkChannel) {
        let a = InMemoryLANLinkChannel(exporter: exporter)
        let b = InMemoryLANLinkChannel(exporter: exporter)
        a.peer = b
        b.peer = a
        return (a, b)
    }

    public func send(_ body: Data) async throws {
        lock.lock()
        let isClosed = closed
        if !isClosed { sent.append(body) }
        let p = peer
        lock.unlock()
        if isClosed { throw LANLinkChannelError.closed }
        guard let p else { throw LANLinkChannelError.closed }
        p.deliver(body)
    }

    private func deliver(_ body: Data) {
        lock.lock(); let isClosed = closed; lock.unlock()
        if !isClosed { inboundContinuation.yield(body) }
    }

    public func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        let p = peer
        lock.unlock()
        inboundContinuation.finish()
        p?.peerDidClose()
    }

    private func peerDidClose() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        inboundContinuation.finish()
    }

    public func exporterSecret(label: String) -> Data? { exporter }
    public var negotiated: LANTransportSecurity.Negotiated? { nil }
}
