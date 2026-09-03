import Foundation
import Network
import CryptoKit

/// TLS parameters for the LAN link — one factory used by BOTH ends, so
/// the phone and the Mac cannot drift apart on version or ciphersuite.
///
/// ── Why TLS 1.2, when the plan said 1.3 ──
///
/// Measured on 2026-09-03, macOS 26.5 / SDK 26.5, NWListener ↔
/// NWConnection on loopback, seven configurations. TLS 1.3 with an
/// external PSK fails the handshake with -9858 **even when both sides
/// hold the same key** — so it is not a derivation bug, it is Apple's
/// stack not supporting TLS 1.3 external PSKs through this API. TLS 1.2
/// PSK suites complete, and the negotiated suite was read back with
/// `sec_protocol_metadata_get_negotiated_tls_ciphersuite` rather than
/// inferred from "bytes arrived":
///
///   TLS 1.3 pinned, AES128-GCM       : handshake failed (-9858)
///   TLS 1.3 pinned, no suite pinned  : handshake failed (-9858)
///   TLS 1.2 + 0x00A8 PSK-AES128-GCM  : ok  → negotiated 0x00A8
///   TLS 1.2 + 0xCCAC ECDHE-PSK-CHACHA: ok  → negotiated 0xCCAC
///   nothing pinned                   : ok  → negotiated **0x00A8**
///
/// Mismatched keys fail in every row — a wrong PSK never delivers an
/// application byte. The probes live next to the internal plan doc; run
/// them on the iPhone before trusting the iOS half.
///
/// ── Why the suite is pinned and not left to negotiation ──
///
/// The last row is the trap: unpinned, the stack picks 0x00A8, a plain
/// PSK suite with NO forward secrecy. The session keys derive from the
/// PSK alone, so anyone who later obtains the Keychain-stored PSK can
/// decrypt every capture they ever made. 0xCCAC mixes in an ephemeral
/// ECDH, so a stolen PSK compromises future sessions only. For a
/// feature whose entire pitch is "the server cannot read this", that is
/// not a nicety. `LANTransportSecurityTests` asserts the suite is pinned
/// and that the negative control (wrong key) still fails.
public enum LANTransportSecurity {

    /// TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905). The only
    /// suite this link will negotiate.
    public static let ciphersuite: UInt16 = 0xCCAC

    /// The one TLS version Apple's stack completes an external-PSK
    /// handshake on. Pinned as both min and max so a downgrade is not a
    /// question the peer gets asked.
    public static let tlsVersion: tls_protocol_version_t = .TLSv12

    /// Size of every PSK this link uses. HKDF output length in
    /// `LANPairing`; also the length `psk(_:)` accepts.
    public static let pskByteCount = 32

    public enum ConfigurationError: Error, Equatable {
        case wrongKeyLength(Int)
        case emptyIdentity
        case unknownCiphersuite
    }

    /// One (identity, key) pair the listener will accept or the client
    /// will present. Identity is what the server uses to pick the key —
    /// RFC 4279 semantics, verified to work with several identities on
    /// one `NWListener` (correct id+key connects; right id + wrong key
    /// fails; unknown id + valid key fails).
    public struct PresharedKey: Sendable, Equatable {
        public let identity: String
        public let key: SymmetricKey

        public init(identity: String, key: SymmetricKey) throws {
            guard !identity.isEmpty else { throw ConfigurationError.emptyIdentity }
            guard key.bitCount == pskByteCount * 8 else {
                throw ConfigurationError.wrongKeyLength(key.bitCount / 8)
            }
            self.identity = identity
            self.key = key
        }

        public static func == (a: PresharedKey, b: PresharedKey) -> Bool {
            a.identity == b.identity && a.key == b.key
        }
    }

    /// Build `NWParameters` for one end of the link.
    ///
    /// A listener passes every paired phone's key; a client passes
    /// exactly one. The same call, so the two ends cannot be configured
    /// differently by accident.
    public static func parameters(presharedKeys: [PresharedKey]) throws -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions

        for psk in presharedKeys {
            psk.key.withUnsafeBytes { (keyBytes: UnsafeRawBufferPointer) in
                let keyDD = DispatchData(bytes: keyBytes)
                let idData = Data(psk.identity.utf8)
                idData.withUnsafeBytes { (idBytes: UnsafeRawBufferPointer) in
                    let idDD = DispatchData(bytes: idBytes)
                    sec_protocol_options_add_pre_shared_key(
                        sec, keyDD as __DispatchData, idDD as __DispatchData)
                }
            }
        }

        guard let suite = tls_ciphersuite_t(rawValue: ciphersuite) else {
            throw ConfigurationError.unknownCiphersuite
        }
        sec_protocol_options_append_tls_ciphersuite(sec, suite)
        sec_protocol_options_set_min_tls_protocol_version(sec, tlsVersion)
        sec_protocol_options_set_max_tls_protocol_version(sec, tlsVersion)

        // PSK: there is no certificate, so the default trust evaluation
        // has nothing to evaluate. Authentication IS the PSK handshake;
        // a peer without the key never reaches application data.
        sec_protocol_options_set_verify_block(sec, { _, _, complete in
            complete(true)
        }, DispatchQueue.global(qos: .utility))

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true          // terminal output is latency-bound
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2

        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false   // LAN only; AWDL is not "same Wi-Fi"
        return params
    }

    /// What was ACTUALLY negotiated on an established connection.
    ///
    /// Exists because "the connection is `.ready`" is not evidence of the
    /// ciphersuite — the measurement above showed the stack quietly
    /// falling back to 0x00A8 when unpinned. Both ends call this after
    /// `.ready` and drop the connection if it does not match; the
    /// negative control for the acceptance run reads it too.
    public struct Negotiated: Equatable, Sendable {
        public let version: tls_protocol_version_t
        public let ciphersuite: UInt16

        public var isExpected: Bool {
            version == LANTransportSecurity.tlsVersion
                && ciphersuite == LANTransportSecurity.ciphersuite
        }
    }

    public static func negotiated(on connection: NWConnection) -> Negotiated? {
        guard let md = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        let sm = md.securityProtocolMetadata
        return Negotiated(
            version: sec_protocol_metadata_get_negotiated_tls_protocol_version(sm),
            ciphersuite: sec_protocol_metadata_get_negotiated_tls_ciphersuite(sm).rawValue)
    }

    /// TLS exporter secret (RFC 5705) bound to THIS connection's
    /// handshake. Used by pairing to derive a short authentication string
    /// that both screens show: a bystander who photographed the QR and
    /// raced the user to connect gets a different exporter, hence a
    /// different code, and the user declines the Mac-side prompt.
    public static func exporterSecret(
        on connection: NWConnection,
        label: String,
        length: Int = 32
    ) -> Data? {
        guard let md = connection.metadata(definition: NWProtocolTLS.definition)
                as? NWProtocolTLS.Metadata else { return nil }
        let sm = md.securityProtocolMetadata
        let labelData = Data(label.utf8)
        let dd: DispatchData? = labelData.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return nil }
            return sec_protocol_metadata_create_secret(sm, raw.count, base.assumingMemoryBound(to: CChar.self), length) as DispatchData?
        }
        guard let secret = dd, secret.count == length else { return nil }
        return Data(secret)
    }
}
