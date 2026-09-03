import Foundation

/// Remote-control M0 — the wire vocabulary between a phone and the Mac
/// app's session-control agent, over the LAN.
///
/// This is deliberately NOT the helper's UDS protocol. The phone speaks
/// to the Mac APP, and the app speaks to the helper; those are two
/// different trust boundaries and two different method namespaces. The
/// helper's `SupportedMethod` is what one process on one Mac may ask a
/// daemon on that Mac; this is what a paired device may ask an app on
/// someone's computer. Keeping them separate is what lets M1 add a
/// vendor-delegation verb (never a helper method) and lets the agent
/// refuse a method by name rather than by inspecting helper params.
///
/// The transport underneath is interchangeable by design — M2 carries
/// the same frames through an E2E-encrypted relay — so nothing here may
/// assume a socket, an address, or Bonjour. Those live in
/// `LANLinkTransport`.
///
/// ── Framing ──
/// Same shape as the helper's UDS framing so a human reading a packet
/// capture sees one convention across the whole system: a 4-byte
/// big-endian length prefix and a UTF-8 JSON body, capped at 1 MiB.
///
/// ── Envelopes ──
/// Every frame carries `"v"`. Four kinds, told apart by which key is
/// present (never by position or by a `type` string that could be
/// omitted):
///
///   request    {"v":1, "id":"…", "m":"sessions.list", "p":{…}}
///   reply      {"v":1, "id":"…", "ok":true,  "r":{…}}
///              {"v":1, "id":"…", "ok":false, "e":{"code":"…","msg":"…"}}
///   event      {"v":1, "ev":"output", "sub":"…", "seq":N, "d":{…}}
///   heartbeat  {"v":1, "hb":<unix seconds>}
///
/// `seq` is per-subscription and strictly monotonic. A gap is how the
/// phone learns it lost frames (a relay reconnect, a dropped Wi-Fi
/// beat) and must resynchronise with `session.tail` — the helper never
/// sends heartbeats, so this is the only liveness the phone gets.
public enum LANLinkProtocol {

    /// Bump when a frame shape changes incompatibly. The agent refuses a
    /// `hello` whose `v` it does not speak, before any other method.
    public static let version = 1

    /// Bonjour service type the agent advertises. Registered in the iOS
    /// Info.plist under `NSBonjourServices` — iOS silently blocks
    /// browsing for a type that is not listed there.
    public static let bonjourServiceType = "_clipulse._tcp"

    /// TXT record keys. The locked decision is that TXT carries ONLY the
    /// device id and the protocol version — no name, no account, nothing
    /// an unpaired observer on the network could use to fingerprint the
    /// user. A display name travels inside the encrypted `hello`.
    public enum TXTKey {
        public static let deviceID = "did"
        public static let protocolVersion = "pv"
        /// Present ONLY on the short-lived pairing service, with value
        /// `TXTMode.pairing`. The steady service omits it. This is the one
        /// addition to the "did + version only" rule, and it reveals
        /// nothing the existence of a second service does not already:
        /// "this Mac has a QR on screen right now".
        public static let mode = "m"
    }

    public enum TXTMode {
        public static let pairing = "pair"
    }

    /// 1 MiB — identical to HelperKit's `Framing.maxPayload`, so a frame
    /// the helper would accept is never too large for the phone link and
    /// vice versa.
    public static let maxFrameBytes = 1 << 20

    /// The agent ticks a heartbeat this often. On the same tick it
    /// re-checks the helper's `local_control_enabled` — the helper only
    /// checks that gate once, before the subscription ack, so without
    /// this re-check flipping the toggle off would not stop a stream
    /// that is already flowing.
    public static let heartbeatInterval: TimeInterval = 1.0

    /// Either side treats the peer as gone after this much silence. The
    /// M0 acceptance criterion is "Mac drops off Wi-Fi ⇒ phone shows
    /// disconnected within 3 s", and this is the number that makes it so.
    public static let peerSilenceTimeout: TimeInterval = 3.0

    // MARK: - Methods

    /// The complete set of verbs a phone can send. Closed enum on
    /// purpose: a method the agent has not been taught is refused at
    /// decode, before any params are looked at.
    ///
    /// M0 is read-only. The M1 verbs are DECLARED so their spellings are
    /// pinned now and a test can assert the agent refuses them; each is
    /// implemented in M1 by replacing a `notImplemented` throw with a
    /// body, not by touching the namespace.
    public enum Method: String, CaseIterable, Sendable {
        // ── M0: read-only ──
        case hello
        case ping
        case sessionsList = "sessions.list"
        case sessionTail = "session.tail"
        case sessionSubscribe = "session.subscribe"
        case sessionUnsubscribe = "session.unsubscribe"

        // ── M1: control (declared, refused until M1) ──
        case sessionInput = "session.input"
        case sessionResize = "session.resize"
        case sessionStart = "session.start"
        case sessionStop = "session.stop"
        case approvalDecide = "approval.decide"

        /// Verbs the agent honours today. Anything else in the enum is
        /// refused with `not_implemented`. This set — not the enum — is
        /// the M0 allowlist, and `LANLinkProtocolTests` pins it.
        public static let readOnly: Set<Method> = [
            .hello, .ping, .sessionsList, .sessionTail,
            .sessionSubscribe, .sessionUnsubscribe,
        ]

        public var isReadOnly: Bool { Self.readOnly.contains(self) }
    }

    // MARK: - Event kinds

    /// What the agent pushes on a subscription. Mapped from the helper's
    /// `LocalSessionEvent` by the agent — the phone never sees helper
    /// event names, which is what lets the helper rename or add one
    /// without a phone update.
    public enum EventKind: String, Sendable {
        /// Terminal bytes, already redacted at egress. `d.bytes_b64`.
        case output
        case sessionStarted = "session_started"
        case sessionStopped = "session_stopped"
        case sessionStatus = "session_status"
        /// The agent is tearing the subscription down and says why.
        /// `d.reason` ∈ `SubscriptionEndReason`.
        case subscriptionEnded = "subscription_ended"
    }

    /// Why a subscription ended, as sent in `subscription_ended`.
    public enum SubscriptionEndReason: String, Sendable {
        /// The user turned local control off on the Mac. This is the
        /// user's revocation lever and MUST close in-flight streams.
        case localControlDisabled = "local_control_disabled"
        case helperGone = "helper_gone"
        case sessionGone = "session_gone"
        case clientRequested = "client_requested"
    }

    // MARK: - Error codes

    /// Wire error codes. Where a code already exists in the helper's
    /// vocabulary (`SessionControlErrorMapping`) the SAME string is used,
    /// so the phone can route both through one table; the few that are
    /// agent-specific are listed under their own heading.
    public enum ErrorCode {
        // Shared with the helper's wire vocabulary.
        public static let unauthenticated = "unauthenticated"
        public static let versionMismatch = "version_mismatch"
        public static let notImplemented = "not_implemented"
        public static let localControlOff = "local_control_off"
        public static let badRequest = "bad_request"
        public static let sessionNotFound = "session_not_found"
        public static let internalError = "internal"
        public static let frameTooLarge = "frame_too_large"

        // Agent-specific.
        /// The Mac app could not reach its helper. Mapped to
        /// `SessionControlError.helperNotRunning` on the phone.
        public static let helperNotRunning = "helper_not_running"
        /// The phone asked for a subscription id it does not hold.
        public static let subscriptionNotFound = "subscription_not_found"
        /// Too many concurrent subscriptions from one connection.
        public static let subscriptionLimit = "subscription_limit"
    }

    /// A connection may hold at most this many live subscriptions. One
    /// terminal on a phone screen needs one; this leaves room for a
    /// picker that pre-warms the next session without letting a buggy
    /// client fan out unboundedly.
    public static let maxSubscriptionsPerConnection = 4
}

// MARK: - Frames

/// One decoded frame off the link. `classify` is the ONLY place that
/// decides what a frame is, and it does so by key presence — the same
/// rule the helper client uses to tell a reply from a stream event.
public enum LANLinkFrame: Equatable, Sendable {
    case request(id: String, method: String, params: [String: AnySendableJSON])
    case reply(id: String, ok: Bool, result: [String: AnySendableJSON], error: LANLinkWireError?)
    case event(kind: String, subscription: String, seq: UInt64, data: [String: AnySendableJSON])
    case heartbeat(ts: TimeInterval)

    /// Frames whose `v` is not ours, or which match no envelope shape.
    /// Surfaced as a value so the agent can log and close rather than
    /// silently drop — a silent drop looks identical to packet loss.
    public enum DecodeError: Error, Equatable {
        case invalidJSON
        case unsupportedVersion(Int?)
        case unrecognisedShape
        case tooLarge(Int)
    }

    // MARK: encode

    public func encode() throws -> Data {
        let dict: [String: Any]
        switch self {
        case let .request(id, method, params):
            dict = ["v": LANLinkProtocol.version, "id": id, "m": method,
                    "p": params.mapValues { $0.value }]
        case let .reply(id, ok, result, error):
            var d: [String: Any] = ["v": LANLinkProtocol.version, "id": id, "ok": ok]
            if ok {
                d["r"] = result.mapValues { $0.value }
            } else {
                d["e"] = ["code": error?.code ?? LANLinkProtocol.ErrorCode.internalError,
                          "msg": error?.message ?? ""]
            }
            dict = d
        case let .event(kind, subscription, seq, data):
            dict = ["v": LANLinkProtocol.version, "ev": kind, "sub": subscription,
                    "seq": seq, "d": data.mapValues { $0.value }]
        case let .heartbeat(ts):
            dict = ["v": LANLinkProtocol.version, "hb": ts]
        }
        let body = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        if body.count > LANLinkProtocol.maxFrameBytes {
            throw DecodeError.tooLarge(body.count)
        }
        return body
    }

    // MARK: decode

    public static func decode(_ body: Data) throws -> LANLinkFrame {
        if body.count > LANLinkProtocol.maxFrameBytes {
            throw DecodeError.tooLarge(body.count)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let dict = raw as? [String: Any] else {
            throw DecodeError.invalidJSON
        }
        return try classify(dict)
    }

    /// Key-presence classification. Order matters only for malformed
    /// frames that carry several markers; a well-formed frame has one.
    public static func classify(_ dict: [String: Any]) throws -> LANLinkFrame {
        let v = dict["v"] as? Int
        guard v == LANLinkProtocol.version else {
            throw DecodeError.unsupportedVersion(v)
        }
        if let hb = dict["hb"] as? Double {
            return .heartbeat(ts: hb)
        }
        if let ev = dict["ev"] as? String,
           let sub = dict["sub"] as? String,
           let seqAny = dict["seq"] {
            let seq: UInt64
            if let n = seqAny as? UInt64 { seq = n }
            else if let n = seqAny as? Int, n >= 0 { seq = UInt64(n) }
            else if let n = seqAny as? Double, n >= 0 { seq = UInt64(n) }
            else { throw DecodeError.unrecognisedShape }
            let data = (dict["d"] as? [String: Any]) ?? [:]
            return .event(kind: ev, subscription: sub, seq: seq,
                          data: AnySendableJSON.wrap(data))
        }
        if let id = dict["id"] as? String, let ok = dict["ok"] as? Bool {
            if ok {
                let r = (dict["r"] as? [String: Any]) ?? [:]
                return .reply(id: id, ok: true, result: AnySendableJSON.wrap(r), error: nil)
            }
            let e = (dict["e"] as? [String: Any]) ?? [:]
            let err = LANLinkWireError(
                code: (e["code"] as? String) ?? LANLinkProtocol.ErrorCode.internalError,
                message: (e["msg"] as? String) ?? "")
            return .reply(id: id, ok: false, result: [:], error: err)
        }
        if let id = dict["id"] as? String, let m = dict["m"] as? String {
            let p = (dict["p"] as? [String: Any]) ?? [:]
            return .request(id: id, method: m, params: AnySendableJSON.wrap(p))
        }
        throw DecodeError.unrecognisedShape
    }
}

/// Error half of a failed reply.
public struct LANLinkWireError: Equatable, Sendable {
    public let code: String
    public let message: String
    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    /// Route to the shared typed error. Agent-specific codes are handled
    /// first; everything else goes through the helper's existing table so
    /// the phone and the Mac agree on what `session_not_found` means.
    public var asSessionControlError: SessionControlError {
        switch code {
        case LANLinkProtocol.ErrorCode.helperNotRunning: return .helperNotRunning
        case LANLinkProtocol.ErrorCode.subscriptionNotFound,
             LANLinkProtocol.ErrorCode.subscriptionLimit:
            return .invalidResponse("\(code): \(message)")
        default:
            return SessionControlErrorMapping.error(forWireCode: code, message: message)
        }
    }
}

/// A JSON scalar/container that is `Sendable` and `Equatable`, so frames
/// can cross actor boundaries and be compared in tests without dragging
/// `Any` through everything. Only the JSON types JSONSerialization
/// produces are representable; anything else wraps to `.null`.
public enum AnySendableJSON: Equatable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([AnySendableJSON])
    case object([String: AnySendableJSON])

    public init(_ any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            // JSONSerialization hands back NSNumber for booleans AND
            // numbers, and `NSNumber as? Bool` SUCCEEDS for 0 and 1 — so
            // a `case let b as Bool` ahead of this turned `"v": 1` into
            // `true` and `exit_code: 0` into `false`. The loopback tests
            // caught it; the round-trip tests had not, because none of
            // their values happened to be 0 or 1. The only reliable
            // discriminator is the underlying CF type.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if n.doubleValue == n.doubleValue.rounded(), abs(n.doubleValue) < 9e15 {
                self = .int(n.intValue)
            } else {
                self = .double(n.doubleValue)
            }
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let a as [Any]: self = .array(a.map(AnySendableJSON.init))
        case let o as [String: Any]: self = .object(AnySendableJSON.wrap(o))
        default: self = .null
        }
    }

    public static func wrap(_ dict: [String: Any]) -> [String: AnySendableJSON] {
        dict.mapValues(AnySendableJSON.init)
    }

    /// Back to Foundation for JSONSerialization.
    public var value: Any {
        switch self {
        case let .string(s): return s
        case let .int(i): return i
        case let .double(d): return d
        case let .bool(b): return b
        case .null: return NSNull()
        case let .array(a): return a.map { $0.value }
        case let .object(o): return o.mapValues { $0.value }
        }
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var intValue: Int? {
        switch self {
        case let .int(i): return i
        case let .double(d) where d == d.rounded(): return Int(d)
        default: return nil
        }
    }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var objectValue: [String: AnySendableJSON]? { if case let .object(o) = self { return o }; return nil }
    public var arrayValue: [AnySendableJSON]? { if case let .array(a) = self { return a }; return nil }
}

// MARK: - Length-prefixed framing over a byte stream

/// Splits a byte stream into frames and joins frames into a byte stream,
/// with the same 4-byte big-endian header as HelperKit's `Framing`. Pure
/// value type: feed it bytes, take frames; no socket in sight, so it is
/// unit-testable and reusable by M2's relay.
public struct LANLinkFramer: Sendable {
    public enum FrameError: Error, Equatable {
        case tooLarge(claimed: Int)
    }

    private var buffer = Data()

    public init() {}

    /// Wrap one body in a length header.
    public static func frame(_ body: Data) throws -> Data {
        if body.count > LANLinkProtocol.maxFrameBytes {
            throw FrameError.tooLarge(claimed: body.count)
        }
        var out = Data(capacity: 4 + body.count)
        var len = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    /// Append incoming bytes and return every complete frame body now
    /// available. A header claiming more than the cap throws BEFORE the
    /// body is buffered — the same early-reject the helper does — and the
    /// caller must close the connection; the framer is unusable after.
    public mutating func append(_ bytes: Data) throws -> [Data] {
        buffer.append(bytes)
        var frames: [Data] = []
        while buffer.count >= 4 {
            let claimed = buffer.withUnsafeBytes { raw -> Int in
                Int(UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self)))
            }
            if claimed > LANLinkProtocol.maxFrameBytes {
                throw FrameError.tooLarge(claimed: claimed)
            }
            guard buffer.count >= 4 + claimed else { break }
            frames.append(buffer.subdata(in: 4..<(4 + claimed)))
            buffer.removeSubrange(0..<(4 + claimed))
        }
        return frames
    }

    public var pendingByteCount: Int { buffer.count }
}
