#if os(macOS)
import XCTest
import Network
import CryptoKit
@testable import CLIPulseCore

/// `LANLinkAgent.remoteHost(of:)` turns an accepted `NWConnection` into the
/// string every downstream decision depends on — it is what `classifyPeer`
/// classifies, and therefore what decides whether the §8 LAN latch fires.
///
/// Before this file it had **no test at all**, and it rests on an assumption
/// worth checking rather than believing: it reads `conn.currentPath?
/// .remoteEndpoint`, not `conn.endpoint`, and `currentPath` is not documented
/// to be populated at the instant `.ready` fires. If it were nil there, the
/// latch would silently never fire and the failure would be indistinguishable
/// from "the peer classified to nil" and from "accept never ran" — three
/// causes, one non-observation.
///
/// These drive a REAL `NWListener` over the REAL TLS-PSK parameters and read
/// what the agent's own function sees, rather than asserting on a string
/// literal the way `LANPeerClassificationTests` does.
final class LANPeerHostObservationTests: XCTestCase {

    private func psk(_ s: String) throws -> LANTransportSecurity.PresharedKey {
        try .init(identity: "peer", key: SymmetricKey(data: SHA256.hash(data: Data(s.utf8))))
    }

    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    /// Result of one accepted connection, observed through the agent's own lens.
    private final class Observed: @unchecked Sendable {
        var host: String?
        var kind: LANDirectAddress.Kind??
        var reachedReady = false
    }

    /// Stand up a listener, dial it at `makeEndpoint`, and report what
    /// `LANLinkAgent.remoteHost` saw on the ACCEPTED side.
    ///
    /// `async`, and deliberately not semaphore-driven: `remoteHost` is
    /// MainActor-isolated (its owner is a `@MainActor` class), so observing it
    /// needs a hop to the main actor — and XCTest's own body runs there. A
    /// semaphore wait on the test thread deadlocks the very hop it is waiting
    /// for, which presents as "the connection never reached .ready" and looks
    /// exactly like a product failure. It is not.
    private func observePeer(dialing makeEndpoint: (NWEndpoint.Port) -> NWEndpoint?,
                             timeout: TimeInterval = 8) async throws -> Observed {
        let observed = Observed()
        let q = DispatchQueue(label: "peer.observe")
        let key = try psk("shared")

        let listener = try NWListener(using: try LANTransportSecurity.parameters(presharedKeys: [key]))
        let once = OnceBox()
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { st in
                if case .ready = st { if once.first() { k.resume() } }
                if case .failed = st { if once.first() { k.resume() } }
            }
            listener.newConnectionHandler = { conn in
                conn.stateUpdateHandler = { st in
                    guard case .ready = st else { return }
                    Task { @MainActor in
                        observed.reachedReady = true
                        let h = LANLinkAgent.remoteHost(of: conn)
                        observed.host = h
                        observed.kind = h.map { LANDirectAddress.classifyPeer($0) }
                    }
                }
                conn.start(queue: q)
            }
            listener.start(queue: q)
        }
        guard let port = listener.port else { listener.cancel(); XCTFail("listener has no port"); return observed }
        guard let endpoint = makeEndpoint(port) else { listener.cancel(); return observed }

        let client = NWConnection(to: endpoint, using: try LANTransportSecurity.parameters(presharedKeys: [key]))
        client.start(queue: q)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: { observed.host }) != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        client.cancel(); listener.cancel()
        return observed
    }

    /// THE ASSUMPTION UNDER TEST. Always runs: loopback exists everywhere,
    /// including the CI runner. If `currentPath` were nil at `.ready`, this is
    /// where it shows up — as a nil host rather than as a mysteriously absent
    /// latch weeks later.
    func test_remoteHostIsPopulatedTheMomentTheConnectionIsReady() async throws {
        let o = try await observePeer(dialing: { .hostPort(host: .ipv4(.loopback), port: $0) })
        XCTAssertTrue(o.reachedReady, "the connection never reached .ready — the observation is void")
        let host = try XCTUnwrap(o.host,
                                 "remoteHost returned nil on a ready connection: `currentPath` is not "
                                 + "populated at .ready, so the latch can never fire. Fall back to conn.endpoint.")
        XCTAssertTrue(host.hasPrefix("127."), "expected the loopback peer, saw \(host)")
        // Loopback deliberately does NOT count — a peer on this machine is not
        // a phone on a network. Pins that the wiring is live AND that its
        // answer here is the intended nil.
        XCTAssertEqual(o.kind, .some(.none), "loopback must stay unclassified, saw \(String(describing: o.kind))")
    }

    /// The half the 2026-09-07 hardware run could not reach: on that network a
    /// client resolving Bonjour arrived on IPv4 both times, and
    /// `LANDirectAddress.parse` rejects `%`, so a link-local address cannot be
    /// typed in either. This produces one on purpose and checks the agent
    /// observes it as link-local and counts it.
    func test_aLinkLocalPeerIsObservedAsLinkLocalAndCountsAsLAN() async throws {
        let linkLocal = LANDirectAddress.localInterfaceAddresses()
            .first { $0.address.lowercased().hasPrefix("fe80:") && !$0.interface.hasPrefix("awdl") }
        guard let ll = linkLocal else {
            throw XCTSkip("this machine has no usable IPv6 link-local address")
        }
        // Network.framework wants the zone on the address itself.
        let scoped = ll.address.contains("%") ? ll.address : "\(ll.address)%\(ll.interface)"
        guard let v6 = IPv6Address(scoped) else {
            throw XCTSkip("could not form an IPv6 address from \(scoped)")
        }

        let o = try await observePeer(dialing: { .hostPort(host: .ipv6(v6), port: $0) })
        guard o.reachedReady else {
            throw XCTSkip("no link-local route on this machine (\(scoped)) — nothing to observe")
        }
        let host = try XCTUnwrap(o.host, "remoteHost returned nil for a link-local peer")
        XCTAssertTrue(host.lowercased().hasPrefix("fe80:"),
                      "expected a link-local peer, saw \(host)")
        XCTAssertEqual(o.kind, .some(.lan),
                       "a link-local arrival must count as LAN — this is the whole point of "
                       + "classifyPeer, and the advertise-side `classify` returns nil here")
        // The negative half, so this cannot pass by everything being .lan:
        XCTAssertNil(LANDirectAddress.classify(host),
                     "the advertise-side allowlist changed meaning; it must still refuse fe80::")
    }
}
#endif
