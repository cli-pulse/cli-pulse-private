import Foundation
import CryptoKit

/// The pairing handshake, both halves, over any `LANLinkChannel`.
///
/// Runs on the PAIRING listener only — a connection there has already
/// proven it holds the QR nonce (TLS-PSK with the pairing key), so the
/// steady-state router is never involved and never learns the verbs
/// below. That separation is what stops a phone that scanned a QR from
/// claiming to be an already-paired peer: the pairing listener cannot
/// serve sessions, full stop.
///
/// ── Frames (request/reply, same envelope as everything else) ──
///
///   phone → `pair.exchange` {pk, id, name}      the phone's X25519
///                                               public key, device id,
///                                               display name
///   mac   ← reply           {pk, did, name}     the Mac's
///   (both compute the SAS from the TLS exporter; both screens show it)
///   phone → `pair.await`    {}                  blocks until the user
///                                               decides on the Mac
///   mac   ← reply           {approved: true}    or error `pairing_rejected`
///                                               / `pairing_expired`
///
/// The SAS is never sent. If the Mac transmitted it, a bystander who won
/// the race to connect would simply display what the Mac sent, and the
/// user would see matching codes on an attacker's phone and their own
/// Mac. Each side derives it from its own end of the handshake.
public enum LANPairingSession {

    public enum Method: String, Sendable {
        case exchange = "pair.exchange"
        case await_ = "pair.await"
    }

    public enum ErrorCode {
        public static let rejected = "pairing_rejected"
        public static let expired = "pairing_expired"
        public static let badExchange = "pairing_bad_exchange"
        public static let outOfOrder = "pairing_out_of_order"
    }

    public static let sasExporterLabel = "clipulse-lan-sas-v1"

    public enum Failure: Error, Equatable {
        case channelClosed
        case noExporter
        case badExchange(String)
        case rejected
        case expired
        case protocolViolation(String)
        case transport(String)
    }

    // MARK: - Mac side

    public actor Agent {
        public enum Outcome: Equatable, Sendable {
            case paired(LANPairing.PairedPeer)
            case rejected
            case expired
            case failed(String)
        }

        private let channel: any LANLinkChannel
        private let identity: LANPairing.LocalIdentity
        private let displayName: String
        private let payload: LANPairing.QRPayload
        private let decide: @Sendable (_ sas: String, _ peerName: String) async -> Bool
        private let clock: @Sendable () -> Date

        public init(
            channel: any LANLinkChannel,
            identity: LANPairing.LocalIdentity,
            displayName: String,
            payload: LANPairing.QRPayload,
            decide: @escaping @Sendable (_ sas: String, _ peerName: String) async -> Bool,
            clock: @escaping @Sendable () -> Date = { Date() }
        ) {
            self.channel = channel
            self.identity = identity
            self.displayName = displayName
            self.payload = payload
            self.decide = decide
            self.clock = clock
        }

        public func run() async -> Outcome {
            defer { channel.close() }
            do {
                // 1. exchange
                let (exID, exParams) = try await nextRequest(expecting: .exchange)
                guard let pkB64 = exParams["pk"]?.stringValue, let pkRaw = Data(base64Encoded: pkB64),
                      let phonePub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkRaw),
                      let phoneID = exParams["id"]?.stringValue, !phoneID.isEmpty else {
                    await reply(exID, error: ErrorCode.badExchange, "pk/id missing or malformed")
                    return .failed("bad exchange")
                }
                let phoneName = exParams["name"]?.stringValue ?? "iPhone"
                await reply(exID, result: [
                    "pk": .string(identity.publicKey.rawRepresentation.base64EncodedString()),
                    "did": .string(identity.deviceID),
                    "name": .string(displayName),
                ])

                // 2. SAS from the exporter — ours, never the peer's.
                guard let exporter = channel.exporterSecret(label: sasExporterLabel) else {
                    return .failed("no exporter secret")
                }
                let sas = LANPairing.shortAuthString(exporterSecret: exporter)

                // 3. wait for the phone to ask, then for the user to decide
                let (awID, _) = try await nextRequest(expecting: .await_)
                if payload.isExpired(now: clock()) {
                    await reply(awID, error: ErrorCode.expired, "QR expired")
                    return .expired
                }
                let approved = await withDeadline(payload.expiresAt) { await self.decide(sas, phoneName) } ?? false
                if payload.isExpired(now: clock()) {
                    await reply(awID, error: ErrorCode.expired, "QR expired")
                    return .expired
                }
                guard approved else {
                    await reply(awID, error: ErrorCode.rejected, "declined on the Mac")
                    return .rejected
                }

                // 4. derive + store
                let key = try LANPairing.sessionKey(
                    myPrivateKey: identity.privateKey, peerPublicKey: phonePub,
                    macPublicKey: identity.publicKey, phonePublicKey: phonePub,
                    nonce: payload.nonce)
                let peer = try LANPairing.PairedPeer(
                    id: phoneID, displayName: phoneName,
                    pskIdentity: LANPairing.pskIdentity(phoneID: phoneID),
                    sessionKey: key, peerPublicKey: phonePub, pairedAt: clock())
                await reply(awID, result: ["approved": .bool(true)])
                return .paired(peer)
            } catch let f as Failure {
                switch f {
                case .rejected: return .rejected
                case .expired: return .expired
                default: return .failed("\(f)")
                }
            } catch {
                return .failed("\(error)")
            }
        }

        private func nextRequest(expecting: Method) async throws -> (String, [String: AnySendableJSON]) {
            let deadline = payload.expiresAt
            let inbound = channel.inbound
            let result: (String, [String: AnySendableJSON])? = await withDeadline(deadline) {
                do {
                    for try await body in inbound {
                        guard let f = try? LANLinkFrame.decode(body) else {
                            throw Failure.protocolViolation("undecodable frame")
                        }
                        switch f {
                        case .heartbeat: continue
                        case let .request(id, m, p):
                            guard m == expecting.rawValue else {
                                await self.reply(id, error: ErrorCode.outOfOrder, "expected \(expecting.rawValue)")
                                throw Failure.protocolViolation("out of order: \(m)")
                            }
                            return (id, p)
                        default:
                            throw Failure.protocolViolation("server-only frame from client")
                        }
                    }
                    throw Failure.channelClosed
                } catch {
                    return nil
                }
            }
            guard let result else {
                if payload.isExpired(now: clock()) { throw Failure.expired }
                throw Failure.channelClosed
            }
            return result
        }

        private func reply(_ id: String, result: [String: AnySendableJSON]) async {
            try? await channel.send(try LANLinkFrame.reply(id: id, ok: true, result: result, error: nil).encode())
        }

        private func reply(_ id: String, error code: String, _ msg: String) async {
            try? await channel.send(try LANLinkFrame.reply(
                id: id, ok: false, result: [:], error: LANLinkWireError(code: code, message: msg)).encode())
        }

        /// Run `op` but give up at `deadline`. Nil on timeout.
        private func withDeadline<T: Sendable>(_ deadline: Date, _ op: @escaping @Sendable () async -> T?) async -> T? {
            let remaining = deadline.timeIntervalSince(clock())
            guard remaining > 0 else { return nil }
            return await withTaskGroup(of: T?.self) { group in
                group.addTask { await op() }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }

    // MARK: - Phone side

    public enum Client {
        /// Run the phone half over an open channel. `onSAS` fires as soon
        /// as the code is computable so the UI can show it while the user
        /// looks at the Mac.
        public static func pair(
            channel: any LANLinkChannel,
            identity: LANPairing.LocalIdentity,
            displayName: String,
            payload: LANPairing.QRPayload,
            onSAS: @escaping @Sendable (String) -> Void,
            clock: @escaping @Sendable () -> Date = { Date() }
        ) async throws -> LANPairing.PairedPeer {
            defer { channel.close() }
            let inbound = channel.inbound
            var iterator = inbound.makeAsyncIterator()

            func awaitReply(id: String) async throws -> [String: AnySendableJSON] {
                while let body = try await iterator.next() {
                    guard let f = try? LANLinkFrame.decode(body) else {
                        throw Failure.protocolViolation("undecodable frame")
                    }
                    switch f {
                    case .heartbeat: continue
                    case let .reply(rid, ok, r, e) where rid == id:
                        if ok { return r }
                        switch e?.code {
                        case ErrorCode.rejected: throw Failure.rejected
                        case ErrorCode.expired: throw Failure.expired
                        default: throw Failure.badExchange(e?.message ?? "error")
                        }
                    default: continue
                    }
                }
                throw Failure.channelClosed
            }

            // 1. exchange
            let exID = UUID().uuidString
            try await channel.send(try LANLinkFrame.request(id: exID, method: Method.exchange.rawValue, params: [
                "pk": .string(identity.publicKey.rawRepresentation.base64EncodedString()),
                "id": .string(identity.deviceID),
                "name": .string(displayName),
            ]).encode())
            let ex = try await awaitReply(id: exID)
            guard let pkB64 = ex["pk"]?.stringValue, let pkRaw = Data(base64Encoded: pkB64),
                  let macPub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pkRaw),
                  let macID = ex["did"]?.stringValue, macID == payload.deviceID else {
                throw Failure.badExchange("Mac's reply did not match the QR")
            }
            let macName = ex["name"]?.stringValue ?? "Mac"

            // 2. SAS
            guard let exporter = channel.exporterSecret(label: sasExporterLabel) else { throw Failure.noExporter }
            onSAS(LANPairing.shortAuthString(exporterSecret: exporter))

            // 3. wait for the user on the Mac
            let awID = UUID().uuidString
            try await channel.send(try LANLinkFrame.request(id: awID, method: Method.await_.rawValue, params: [:]).encode())
            let aw = try await awaitReply(id: awID)
            guard aw["approved"]?.boolValue == true else { throw Failure.rejected }

            // 4. derive + return
            let key = try LANPairing.sessionKey(
                myPrivateKey: identity.privateKey, peerPublicKey: macPub,
                macPublicKey: macPub, phonePublicKey: identity.publicKey,
                nonce: payload.nonce)
            return try LANPairing.PairedPeer(
                id: macID, displayName: macName,
                pskIdentity: LANPairing.pskIdentity(phoneID: identity.deviceID),
                sessionKey: key, peerPublicKey: macPub, pairedAt: clock())
        }
    }
}
