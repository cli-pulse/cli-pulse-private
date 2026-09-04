import XCTest
import Network
import CryptoKit
@testable import CLIPulseCore

/// Remote-control M0 — the TLS-PSK layer, tested against the REAL
/// Network.framework stack on loopback rather than a mock.
///
/// A mock would have passed with TLS 1.3, which the real stack refuses.
/// That is the whole reason these are live: the measurement that chose
/// TLS 1.2 + 0xCCAC has to stay true on every machine that runs CI.
final class LANTransportSecurityTests: XCTestCase {

    private func psk(_ seed: String, identity: String = "peer:test") throws
        -> LANTransportSecurity.PresharedKey {
        try LANTransportSecurity.PresharedKey(
            identity: identity,
            key: SymmetricKey(data: SHA256.hash(data: Data(seed.utf8))))
    }

    // MARK: - Configuration validation

    func testPresharedKeyRefusesWrongLength() {
        XCTAssertThrowsError(
            try LANTransportSecurity.PresharedKey(identity: "x", key: SymmetricKey(size: .bits128))
        ) { e in
            XCTAssertEqual(e as? LANTransportSecurity.ConfigurationError, .wrongKeyLength(16))
        }
    }

    func testPresharedKeyRefusesEmptyIdentity() {
        XCTAssertThrowsError(
            try LANTransportSecurity.PresharedKey(identity: "", key: SymmetricKey(size: .bits256))
        ) { e in
            XCTAssertEqual(e as? LANTransportSecurity.ConfigurationError, .emptyIdentity)
        }
    }

    func testPinnedSuiteIsForwardSecretECDHEPSK() {
        // 0xCCAC = TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256. If this
        // ever changes to 0x00A8 (plain PSK), forward secrecy is gone.
        XCTAssertEqual(LANTransportSecurity.ciphersuite, 0xCCAC)
        XCTAssertEqual(LANTransportSecurity.tlsVersion, .TLSv12)
    }

    // MARK: - Live loopback

    /// Result of one client→listener attempt.
    private struct Outcome {
        var delivered = false
        var negotiated: LANTransportSecurity.Negotiated?
        var clientError: String?
    }

    private func attempt(
        serverKeys: [LANTransportSecurity.PresharedKey],
        clientKey: LANTransportSecurity.PresharedKey,
        timeout: TimeInterval = 6
    ) throws -> Outcome {
        var outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let q = DispatchQueue(label: "lan.tls.test")

        let listener = try NWListener(using: try LANTransportSecurity.parameters(presharedKeys: serverKeys))
        listener.newConnectionHandler = { conn in
            conn.start(queue: q)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16) { data, _, _, _ in
                if let data, !data.isEmpty {
                    outcome.delivered = true
                    done.signal()
                }
            }
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { st in
            if case .ready = st { ready.signal() }
            if case .failed = st { ready.signal() }
        }
        listener.start(queue: q)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success, "listener never became ready")
        guard let port = listener.port else {
            listener.cancel()
            XCTFail("listener has no port")
            return outcome
        }

        let client = NWConnection(host: .ipv4(.loopback), port: port,
                                  using: try LANTransportSecurity.parameters(presharedKeys: [clientKey]))
        client.stateUpdateHandler = { st in
            switch st {
            case .ready:
                outcome.negotiated = LANTransportSecurity.negotiated(on: client)
                client.send(content: Data("X".utf8), completion: .contentProcessed { _ in })
            case .failed(let e):
                outcome.clientError = "\(e)"; done.signal()
            case .waiting(let e):
                outcome.clientError = "\(e)"; done.signal()
            default: break
            }
        }
        client.start(queue: q)
        _ = done.wait(timeout: .now() + timeout)
        client.cancel()
        listener.cancel()
        return outcome
    }

    func testMatchingKeyNegotiatesExactlyThePinnedSuite() throws {
        let k = try psk("shared")
        let r = try attempt(serverKeys: [k], clientKey: k)
        XCTAssertTrue(r.delivered, "application byte did not cross: \(r.clientError ?? "-")")
        let n = try XCTUnwrap(r.negotiated, "no TLS metadata on a ready connection")
        XCTAssertEqual(n.version, .TLSv12)
        XCTAssertEqual(n.ciphersuite, 0xCCAC,
                       "negotiated 0x\(String(n.ciphersuite, radix: 16)) — forward secrecy lost")
        XCTAssertTrue(n.isExpected)
    }

    func testWrongKeyNeverDeliversAnApplicationByte() throws {
        // THE negative control from the acceptance criteria. If this
        // ever delivers, the PSK is not authenticating anything.
        let good = try psk("shared")
        let bad = try psk("attacker")
        let r = try attempt(serverKeys: [good], clientKey: bad, timeout: 4)
        XCTAssertFalse(r.delivered, "wrong PSK delivered application data")
        XCTAssertNil(r.negotiated, "wrong PSK reached .ready")
    }

    func testOneListenerSelectsAmongSeveralIdentities() throws {
        // RFC 4279 semantics on Apple's stack, measured 2026-09-03: this
        // is what lets ONE steady listener serve every paired phone.
        let a = try psk("phone-a", identity: "peer:a")
        let b = try psk("phone-b", identity: "peer:b")

        XCTAssertTrue(try attempt(serverKeys: [a, b], clientKey: a).delivered, "A/A")
        XCTAssertTrue(try attempt(serverKeys: [a, b], clientKey: b).delivered, "B/B")

        // Right identity, wrong key.
        let aIDbKey = try LANTransportSecurity.PresharedKey(identity: "peer:a", key: b.key)
        XCTAssertFalse(try attempt(serverKeys: [a, b], clientKey: aIDbKey, timeout: 4).delivered,
                       "identity A with key B must fail")

        // Unknown identity, valid key.
        let cIDaKey = try LANTransportSecurity.PresharedKey(identity: "peer:c", key: a.key)
        XCTAssertFalse(try attempt(serverKeys: [a, b], clientKey: cIDaKey, timeout: 4).delivered,
                       "unknown identity must fail even with a valid key")
    }

    // MARK: - Listener-side identity attribution (remote-control M1)

    /// Which paired phone is on a given accepted connection? The design
    /// review measured that a SERVER-side `pre_shared_key_selection_block`
    /// is invoked with the client's presented PSK identity and that the
    /// metadata object it receives is the same one the accepted
    /// `NWConnection` reports after `.ready` — attribution authenticated by
    /// the handshake itself, no extra wire fields. The SDK header words the
    /// block for the client side, so this pins the server-side behaviour
    /// the way the ciphersuite is pinned: live, with negative controls.
    func testListenerAttributesEachConnectionToThePresentedIdentity() throws {
        let a = try psk("phone-a", identity: "peer:a")
        let b = try psk("phone-b", identity: "peer:b")
        let (params, registry) = try LANTransportSecurity.listenerParameters(presharedKeys: [a, b])
        let q = DispatchQueue(label: "lan.attr.test")
        let listener = try NWListener(using: params)
        let accepted = NSLock(); var identities: [String] = []
        listener.newConnectionHandler = { conn in
            conn.stateUpdateHandler = { st in
                if case .ready = st {
                    accepted.lock(); identities.append(registry.identity(for: conn) ?? "<none>"); accepted.unlock()
                    conn.send(content: Data("ok".utf8), completion: .contentProcessed { _ in })
                }
            }
            conn.start(queue: q)
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: q)
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port)

        func connect(_ key: LANTransportSecurity.PresharedKey) throws -> Bool {
            let done = DispatchSemaphore(value: 0)
            var delivered = false
            let c = NWConnection(host: .ipv4(.loopback), port: port,
                                 using: try LANTransportSecurity.parameters(presharedKeys: [key]))
            c.stateUpdateHandler = { st in
                switch st {
                case .ready:
                    c.receive(minimumIncompleteLength: 1, maximumLength: 8) { d, _, _, _ in
                        delivered = (d?.isEmpty == false); done.signal()
                    }
                case .failed, .waiting: done.signal()
                default: break
                }
            }
            c.start(queue: q)
            _ = done.wait(timeout: .now() + 4)
            c.cancel()
            return delivered
        }

        XCTAssertTrue(try connect(b), "B/B")
        XCTAssertTrue(try connect(a), "A/A")
        XCTAssertTrue(try connect(b), "B/B again")
        // Negative controls: a wrong key under a known identity, and an
        // unknown identity, must not be attributed to anyone.
        XCTAssertFalse(try connect(try LANTransportSecurity.PresharedKey(identity: "peer:a", key: b.key)), "A id, B key")
        XCTAssertFalse(try connect(try LANTransportSecurity.PresharedKey(identity: "peer:z", key: a.key)), "unknown id")
        usleep(200_000)
        accepted.lock(); let seen = identities; accepted.unlock()
        XCTAssertEqual(seen, ["peer:b", "peer:a", "peer:b"], "one identity per accepted connection, in order")
    }

    func testExporterSecretIsPerHandshake() throws {
        // Two handshakes with the SAME PSK must yield DIFFERENT exporter
        // secrets — that is what makes the pairing SAS bind to one
        // connection rather than to the key.
        let k = try psk("shared")
        var secrets: [Data] = []
        let q = DispatchQueue(label: "lan.exporter.test")

        for _ in 0..<2 {
            let done = DispatchSemaphore(value: 0)
            let listener = try NWListener(using: try LANTransportSecurity.parameters(presharedKeys: [k]))
            listener.newConnectionHandler = { c in c.start(queue: q) }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: q)
            _ = ready.wait(timeout: .now() + 5)
            let port = try XCTUnwrap(listener.port)
            let client = NWConnection(host: .ipv4(.loopback), port: port,
                                      using: try LANTransportSecurity.parameters(presharedKeys: [k]))
            client.stateUpdateHandler = { st in
                if case .ready = st {
                    if let s = LANTransportSecurity.exporterSecret(on: client, label: "clipulse-lan-sas-v1") {
                        secrets.append(s)
                    }
                    done.signal()
                }
                if case .failed = st { done.signal() }
            }
            client.start(queue: q)
            _ = done.wait(timeout: .now() + 6)
            client.cancel(); listener.cancel()
        }

        XCTAssertEqual(secrets.count, 2, "exporter secret unavailable on a ready connection")
        XCTAssertEqual(secrets[0].count, 32)
        XCTAssertNotEqual(secrets[0], secrets[1], "exporter must differ per handshake")
    }
}
