import Foundation
import CryptoKit

/// Remote-control M0 — pairing a phone with a Mac over the LAN.
///
/// ── The shape of it ──
///
///  1. Mac shows a QR: its local device id, a fresh 32-byte nonce, and
///     an expiry 60 s out. It starts a PAIRING listener whose only PSK
///     is derived from that nonce.
///  2. Phone scans, derives the same PSK, connects. TLS-PSK now
///     authenticates both ends to "whoever has the nonce".
///  3. Inside that channel both sides exchange fresh X25519 public keys
///     and compute a short authentication string from the TLS exporter
///     secret. Both screens show it; the user taps Approve on the Mac.
///  4. On approval each side derives the LONG-TERM per-peer PSK from the
///     X25519 shared secret and stores it. The nonce is consumed. The
///     pairing listener stops.
///
/// ── Why the long-term key is NOT derived from the QR ──
///
/// The nonce was displayed on a screen. Anyone who photographed it — a
/// colleague behind the user, a screen recording — can derive anything
/// that is a pure function of it. So the QR only gates the pairing
/// CHANNEL; the keys that outlive pairing come from an ECDH performed
/// inside it, which an observer of the QR cannot reproduce. That is also
/// what makes step 3's code meaningful: an attacker who raced the user
/// to connect first gets a different exporter, hence a different code,
/// and the user sees the mismatch and declines.
///
/// The X25519 keypairs are kept, not discarded: M2's end-to-end relay
/// encrypts frames to the same peer identities, so the relay path
/// inherits pairing rather than needing its own.
///
/// ── Why the device id is local ──
///
/// `deviceID` is generated once and stored in the Keychain. It is NOT
/// the cloud `devices.id`: a Mac may pair over the LAN before (or
/// without ever) registering with the backend, and an id that changed
/// at cloud registration would orphan every phone's stored pairing. If
/// the Mac is cloud-registered it says so inside the encrypted `hello`,
/// where the phone can cross-check it against `state.devices`.
public enum LANPairing {

    /// Wall-clock lifetime of a QR. The Mac stops the pairing listener
    /// at expiry; the phone refuses to attempt an expired payload; and
    /// the nonce is single-use regardless. Three independent closes.
    public static let qrLifetime: TimeInterval = 60

    /// Nonce entropy. 256 bits — the PSK derived from it is the only
    /// thing protecting the pairing channel for those 60 seconds.
    public static let nonceByteCount = 32

    /// Number of decimal digits in the short authentication string.
    public static let sasDigits = 6

    // MARK: - Domain separation labels
    //
    // Every derivation has its own `info`, so a key for one purpose can
    // never be mistaken for another even if the inputs coincide.

    enum Info {
        static let pairingPSK = Data("clipulse-lan-pairing-psk-v1".utf8)
        static let sessionPSK = Data("clipulse-lan-session-psk-v1".utf8)
        static let sas = "clipulse-lan-sas-v1"
    }

    // MARK: - QR payload

    /// What the QR encodes. Serialised as a `clipulse://pair` URL so the
    /// stock Camera app can hand it to the iOS app (the scheme is already
    /// registered in the iOS Info.plist for OAuth).
    public struct QRPayload: Equatable, Sendable, Identifiable {
        public static let scheme = "clipulse"
        public static let host = "pair"

        /// One id per minted code — the nonce is unique per mint, so this
        /// is what lets SwiftUI present a sheet per payload.
        public var id: String { deviceID + ":" + nonce.base64URLEncoded }

        public let version: Int
        public let deviceID: String
        public let nonce: Data
        public let expiresAt: Date

        public init(deviceID: String, nonce: Data, expiresAt: Date,
                    version: Int = LANLinkProtocol.version) {
            self.version = version
            self.deviceID = deviceID
            self.nonce = nonce
            self.expiresAt = expiresAt
        }

        /// Mint a fresh payload for `deviceID`. `now` is injectable so the
        /// expiry test does not have to wait a real minute.
        public static func mint(deviceID: String, now: Date = Date()) -> QRPayload {
            var bytes = [UInt8](repeating: 0, count: nonceByteCount)
            let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
            return QRPayload(deviceID: deviceID, nonce: Data(bytes),
                             expiresAt: now.addingTimeInterval(qrLifetime))
        }

        public func isExpired(now: Date = Date()) -> Bool {
            now >= expiresAt
        }

        public var urlString: String {
            var c = URLComponents()
            c.scheme = Self.scheme
            c.host = Self.host
            c.queryItems = [
                URLQueryItem(name: "v", value: String(version)),
                URLQueryItem(name: "did", value: deviceID),
                URLQueryItem(name: "n", value: nonce.base64URLEncoded),
                URLQueryItem(name: "exp", value: String(Int(expiresAt.timeIntervalSince1970))),
            ]
            return c.string ?? ""
        }

        public enum ParseError: Error, Equatable {
            case notAPairingURL
            case missingField(String)
            case badNonce
            case unsupportedVersion(Int)
        }

        /// Strict parse. Every field is required; a nonce of the wrong
        /// length is refused rather than padded.
        public static func parse(_ string: String) throws -> QRPayload {
            guard let c = URLComponents(string: string),
                  c.scheme == scheme, c.host == host else {
                throw ParseError.notAPairingURL
            }
            var fields: [String: String] = [:]
            for item in c.queryItems ?? [] {
                if let v = item.value { fields[item.name] = v }
            }
            guard let vStr = fields["v"], let v = Int(vStr) else { throw ParseError.missingField("v") }
            guard v == LANLinkProtocol.version else { throw ParseError.unsupportedVersion(v) }
            guard let did = fields["did"], !did.isEmpty else { throw ParseError.missingField("did") }
            guard let nStr = fields["n"] else { throw ParseError.missingField("n") }
            guard let nonce = Data(base64URLEncoded: nStr), nonce.count == nonceByteCount else {
                throw ParseError.badNonce
            }
            guard let expStr = fields["exp"], let exp = TimeInterval(expStr) else {
                throw ParseError.missingField("exp")
            }
            return QRPayload(deviceID: did, nonce: nonce,
                             expiresAt: Date(timeIntervalSince1970: exp), version: v)
        }
    }

    // MARK: - Derivations

    /// Remote-control M1 peer binding.
    ///
    /// A steady connection authenticates that the client holds SOME paired
    /// phone's key (the TLS-PSK handshake), but Apple's stack gives the
    /// SERVER no portable way to read WHICH identity was used — a
    /// listener-side selection block reads it on macOS 26.5 and returns
    /// nothing on the CI runner's older macOS (measured 2026-09-05, that
    /// is why this exists). So the phone proves which paired peer it is at
    /// the application layer: an HMAC over the connection's own RFC 5705
    /// exporter, keyed by the per-peer session key only that phone and
    /// this Mac share. The exporter is unique per handshake (replay-proof)
    /// and the key is secret to the pair (unforgeable) — both things this
    /// code already relies on for the pairing SAS. Documented APIs only.
    public static let peerBindingExporterLabel = "clipulse-lan-peer-binding-v1"

    public static func peerBindingProof(sessionKey: SymmetricKey, exporter: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: exporter, using: sessionKey))
    }

    /// Constant-time verify.
    public static func verifyPeerBinding(sessionKey: SymmetricKey, exporter: Data, proof: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: exporter, using: sessionKey)
    }

    /// PSK for the pairing channel — a pure function of the QR, valid
    /// only while the QR is. Identity is prefixed so a pairing key can
    /// never be confused with a session key on the steady listener.
    public static func pairingPSK(for payload: QRPayload) throws -> LANTransportSecurity.PresharedKey {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: payload.nonce),
            salt: Data(payload.deviceID.utf8),
            info: Info.pairingPSK,
            outputByteCount: LANTransportSecurity.pskByteCount)
        return try LANTransportSecurity.PresharedKey(
            identity: "pair:" + payload.deviceID, key: key)
    }

    /// Long-term per-peer PSK from the in-channel ECDH.
    ///
    /// Both public keys go into `info` in a FIXED order (Mac first) so
    /// each side computes the same key regardless of which role it
    /// played, and so the key is bound to exactly this pair of
    /// identities.
    public static func sessionKey(
        myPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        peerPublicKey: Curve25519.KeyAgreement.PublicKey,
        macPublicKey: Curve25519.KeyAgreement.PublicKey,
        phonePublicKey: Curve25519.KeyAgreement.PublicKey,
        nonce: Data
    ) throws -> SymmetricKey {
        let shared = try myPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
        var info = Info.sessionPSK
        info.append(macPublicKey.rawRepresentation)
        info.append(phonePublicKey.rawRepresentation)
        return shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: nonce,
            sharedInfo: info,
            outputByteCount: LANTransportSecurity.pskByteCount)
    }

    /// The TLS-PSK identity a pairing produces. It names the PHONE on
    /// both ends: the Mac's listener registers it, the phone presents
    /// it. A record's own `id` is the other party, which on the phone
    /// side is the Mac — so the identity cannot be derived from `id`,
    /// and both sides store it explicitly.
    public static func pskIdentity(phoneID: String) -> String { "peer:" + phoneID }

    /// Short authentication string from the TLS exporter. Deterministic
    /// on both ends of ONE handshake; different for any other handshake.
    /// Six digits: enough that a bystander cannot guess it, few enough to
    /// compare at a glance.
    public static func shortAuthString(exporterSecret: Data) -> String {
        precondition(exporterSecret.count >= 4)
        let n = exporterSecret.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let modulus = UInt32(pow(10.0, Double(sasDigits)))
        let digits = n % modulus
        return String(format: "%0\(sasDigits)u", digits)
    }

    // MARK: - Persistent records

    /// This device's own long-lived identity. Generated once.
    public struct LocalIdentity: Equatable, Sendable {
        public let deviceID: String
        public let privateKey: Curve25519.KeyAgreement.PrivateKey

        public init(deviceID: String, privateKey: Curve25519.KeyAgreement.PrivateKey) {
            self.deviceID = deviceID
            self.privateKey = privateKey
        }

        public static func generate() -> LocalIdentity {
            LocalIdentity(deviceID: UUID().uuidString.lowercased(),
                          privateKey: Curve25519.KeyAgreement.PrivateKey())
        }

        public var publicKey: Curve25519.KeyAgreement.PublicKey { privateKey.publicKey }

        public static func == (a: LocalIdentity, b: LocalIdentity) -> Bool {
            a.deviceID == b.deviceID
                && a.privateKey.rawRepresentation == b.privateKey.rawRepresentation
        }

        // Keychain form: a small JSON blob. `KeychainHelper` stores
        // strings, so bytes are base64.
        struct Wire: Codable {
            var did: String
            var sk: String
        }

        public func serialized() throws -> String {
            let w = Wire(did: deviceID, sk: privateKey.rawRepresentation.base64EncodedString())
            return String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        }

        /// Any record that cannot be turned back into a usable identity is
        /// `.corrupt` — the caller's only question is "can I use this",
        /// and a `DecodingError` versus a bad key length is not a
        /// distinction it can act on differently.
        public static func deserialize(_ s: String) throws -> LocalIdentity {
            guard let w = try? JSONDecoder().decode(Wire.self, from: Data(s.utf8)),
                  !w.did.isEmpty,
                  let raw = Data(base64Encoded: w.sk),
                  let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
                throw PairingStoreError.corrupt
            }
            return LocalIdentity(deviceID: w.did, privateKey: key)
        }
    }

    /// A peer this device has paired with. The Mac stores one per phone;
    /// the phone stores one per Mac.
    public struct PairedPeer: Equatable, Sendable, Identifiable {
        public let id: String              // the OTHER party's deviceID
        public let displayName: String
        /// `peer:<phoneID>` on both ends — see `pskIdentity(phoneID:)`.
        public let pskIdentity: String
        public let sessionKey: SymmetricKey
        public let peerPublicKey: Curve25519.KeyAgreement.PublicKey
        public let pairedAt: Date
        /// Remote-control M1: may this peer control sessions (type, resize,
        /// start, stop, decide approvals)? Meaningful on the Mac's records
        /// only. A record written by M0 has no such field and reads back
        /// as false — M0's promise to the user was "watch".
        public let controlAllowed: Bool
        /// The PSK the phone presents and the Mac's listener accepts.
        /// Built once here, so a record that cannot yield a valid PSK
        /// cannot exist — `init` throws instead of a later force-unwrap.
        public let presharedKey: LANTransportSecurity.PresharedKey

        public init(id: String, displayName: String, pskIdentity: String, sessionKey: SymmetricKey,
                    peerPublicKey: Curve25519.KeyAgreement.PublicKey, pairedAt: Date,
                    controlAllowed: Bool = false) throws {
            self.id = id
            self.displayName = displayName
            self.pskIdentity = pskIdentity
            self.sessionKey = sessionKey
            self.peerPublicKey = peerPublicKey
            self.pairedAt = pairedAt
            self.controlAllowed = controlAllowed
            self.presharedKey = try LANTransportSecurity.PresharedKey(identity: pskIdentity, key: sessionKey)
        }

        /// The PHONE's device id, taken from `pskIdentity` ("peer:<phoneID>"),
        /// which both ends store identically.
        ///
        /// The records are ASYMMETRIC: on the Mac `id` is the phone's did,
        /// on the phone `id` is the MAC's did. The Mac keys its stored
        /// peers by the phone's did, so this — not `id` — is what the
        /// phone must send as the binding `did` in hello. Sending `id`
        /// from the phone made every lookup miss and silently downgraded
        /// the link to read-only (caught on hardware 2026-09-05).
        public var phoneDeviceID: String {
            pskIdentity.hasPrefix("peer:") ? String(pskIdentity.dropFirst("peer:".count)) : id
        }

        /// Same peer, different permission. The PSK was validated when
        /// `self` was built, so re-validation cannot fail; a failure here
        /// would be memory corruption, not input.
        public func withControlAllowed(_ allowed: Bool) -> PairedPeer {
            guard let p = try? PairedPeer(id: id, displayName: displayName, pskIdentity: pskIdentity,
                                          sessionKey: sessionKey, peerPublicKey: peerPublicKey,
                                          pairedAt: pairedAt, controlAllowed: allowed) else {
                preconditionFailure("PairedPeer.withControlAllowed: a validated key failed to re-validate")
            }
            return p
        }

        public static func == (a: PairedPeer, b: PairedPeer) -> Bool {
            a.id == b.id && a.displayName == b.displayName
                && a.pskIdentity == b.pskIdentity
                && a.sessionKey == b.sessionKey
                && a.peerPublicKey.rawRepresentation == b.peerPublicKey.rawRepresentation
                && a.pairedAt == b.pairedAt
                && a.controlAllowed == b.controlAllowed
        }

        struct Wire: Codable {
            var id: String
            var name: String
            var pid: String
            var psk: String
            var pk: String
            var at: TimeInterval
            /// Absent on M0 records ⇒ false.
            var ctl: Bool?
        }

        public func serialized() throws -> String {
            let psk = sessionKey.withUnsafeBytes { Data($0).base64EncodedString() }
            let w = Wire(id: id, name: displayName, pid: pskIdentity, psk: psk,
                         pk: peerPublicKey.rawRepresentation.base64EncodedString(),
                         at: pairedAt.timeIntervalSince1970, ctl: controlAllowed)
            return String(decoding: try JSONEncoder().encode(w), as: UTF8.self)
        }

        /// See `LocalIdentity.deserialize` — every failure mode is `.corrupt`.
        public static func deserialize(_ s: String) throws -> PairedPeer {
            guard let w = try? JSONDecoder().decode(Wire.self, from: Data(s.utf8)),
                  !w.id.isEmpty, !w.pid.isEmpty,
                  let psk = Data(base64Encoded: w.psk), psk.count == LANTransportSecurity.pskByteCount,
                  let pk = Data(base64Encoded: w.pk),
                  let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk) else {
                throw PairingStoreError.corrupt
            }
            guard let peer = try? PairedPeer(id: w.id, displayName: w.name, pskIdentity: w.pid,
                                             sessionKey: SymmetricKey(data: psk), peerPublicKey: pub,
                                             pairedAt: Date(timeIntervalSince1970: w.at),
                                             controlAllowed: w.ctl ?? false) else {
                throw PairingStoreError.corrupt
            }
            return peer
        }
    }

    public enum PairingStoreError: Error, Equatable {
        case corrupt
        case keychainWriteFailed
    }
}

// MARK: - base64url

extension Data {
    /// RFC 4648 §5, unpadded — URL-safe for the QR payload.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+")
                 .replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b.append("=") }
        self.init(base64Encoded: b)
    }
}
